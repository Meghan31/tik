//
//  EventTap.swift
//  tik
//
//  System-wide, listen-only keyboard + mouse observation via CGEventTap.
//
//  The tap lives on its own high-priority thread with its own run loop, so a busy main
//  thread (SwiftUI, menus) can never delay sounds or make macOS time the tap out.
//  The callback only reads key code / phase / flags and hands a tiny struct to SoundEngine.
//  It observes; it never modifies, blocks or injects input.
//

import Foundation
import CoreGraphics

nonisolated final class EventTap: @unchecked Sendable {
    private let engine: SoundEngine
    private let stateLock = NSLock()
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var disabledEvents = 0

    init(engine: SoundEngine) {
        self.engine = engine
    }

    private static let eventMask: CGEventMask = {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged,
                                    .leftMouseDown, .leftMouseUp,
                                    .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp]
        var mask: CGEventMask = 0
        for t in types { mask |= CGEventMask(1) << CGEventMask(t.rawValue) }
        return mask
    }()

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        if let refcon {
            let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
            tap.handle(type: type, event: event)
        }
        return Unmanaged.passUnretained(event)
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return port != nil
    }

    /// True if the tap exists and macOS currently has it enabled.
    var isEnabled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let port else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }

    var timeoutRecoveries: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return disabledEvents
    }

    /// Creates the tap. Returns false when macOS refuses, which almost always means
    /// Input Monitoring hasn't been granted (or the app must be relaunched after granting).
    @discardableResult
    func start() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if port != nil { return true }

        guard let newPort = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                              place: .headInsertEventTap,
                                              options: .listenOnly,
                                              eventsOfInterest: EventTap.eventMask,
                                              callback: EventTap.callback,
                                              userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newPort, 0) else {
            CFMachPortInvalidate(newPort)
            return false
        }

        let ready = DispatchSemaphore(value: 0)
        let context = TapThreadContext(port: newPort, source: source)
        let t = Thread {
            let rl = CFRunLoopGetCurrent()
            CFRunLoopAddSource(rl, context.source, .commonModes)
            context.runLoop = rl
            ready.signal()
            CGEvent.tapEnable(tap: context.port, enable: true)
            CFRunLoopRun()
        }
        t.name = "Tik.EventTap"
        t.qualityOfService = .userInteractive
        port = newPort
        t.start()
        ready.wait()
        runLoop = context.runLoop
        thread = t
        return true
    }

    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let p = port else { return }
        CGEvent.tapEnable(tap: p, enable: false)
        if let rl = runLoop { CFRunLoopStop(rl) }
        CFMachPortInvalidate(p)
        port = nil
        runLoop = nil
        thread = nil
    }

    /// Re-enables a tap that macOS switched off (after sleep or a timeout).
    func reenableIfNeeded() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let p = port, !CGEvent.tapIsEnabled(tap: p) {
            CGEvent.tapEnable(tap: p, enable: true)
        }
    }

    // MARK: Tap thread

    private func handle(type: CGEventType, event: CGEvent) {
        let kind: TikEventKind
        var code: UInt16 = 0
        switch type {
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        case .leftMouseDown: kind = .mouseDown; code = MouseCode.left
        case .leftMouseUp: kind = .mouseUp; code = MouseCode.left
        case .rightMouseDown: kind = .mouseDown; code = MouseCode.right
        case .rightMouseUp: kind = .mouseUp; code = MouseCode.right
        case .otherMouseDown: kind = .mouseDown; code = MouseCode.other
        case .otherMouseUp: kind = .mouseUp; code = MouseCode.other
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switched us off; switch straight back on (never in a loop).
            stateLock.lock()
            disabledEvents += 1
            let p = port
            stateLock.unlock()
            if let p { CGEvent.tapEnable(tap: p, enable: true) }
            return
        default:
            return
        }

        if kind == .keyDown || kind == .keyUp || kind == .flagsChanged {
            code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        }
        let isRepeat = kind == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let synthetic = event.getIntegerValueField(.eventSourceStateID)
            != Int64(CGEventSourceStateID.hidSystemState.rawValue)

        engine.handle(TikKeyEvent(kind: kind, keyCode: code, isRepeat: isRepeat, flags: event.flags.rawValue),
                      synthetic: synthetic)
    }
}

/// Carries the Core Foundation objects into the tap thread and its run loop back out.
/// Core Foundation types aren't marked Sendable; access is ordered by the start-up semaphore.
nonisolated private final class TapThreadContext: @unchecked Sendable {
    let port: CFMachPort
    let source: CFRunLoopSource
    var runLoop: CFRunLoop?

    init(port: CFMachPort, source: CFRunLoopSource) {
        self.port = port
        self.source = source
    }
}
