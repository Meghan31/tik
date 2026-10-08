//
//  ToggleShortcut.swift
//  tik
//
//  The "universal" on/off command, designed so it can never disturb another app:
//
//  • Double-tap Right ⌥ Option (default) or Right ⇧ Shift.
//    A modifier tapped on its own types nothing and triggers no app or macOS shortcut,
//    so other apps can't react to it. Detected on the event-tap thread from modifier
//    events only. Any other key, button or modifier in between cancels the gesture,
//    so normal typing (Shift+letter, ⌥+letter, shortcuts) never triggers it.
//
//  • A custom key combination, registered with macOS as an *exclusive* hot key.
//    macOS delivers it only to Tik (the frontmost app never sees it). Tik refuses
//    combinations macOS already uses (System Settings › Keyboard Shortcuts), and
//    registration fails if another app has already claimed the same combination.
//

import Foundation
import AppKit
import Carbon

nonisolated enum ToggleShortcut: String, Codable, CaseIterable, Sendable {
    case doubleTapRightOption
    case doubleTapRightShift
    case keyCombination
    case off

    var label: String {
        switch self {
        case .doubleTapRightOption: return "Double-tap Right ⌥ Option"
        case .doubleTapRightShift: return "Double-tap Right ⇧ Shift"
        case .keyCombination: return "Key combination…"
        case .off: return "Off"
        }
    }

    /// Modifier key code watched for a double tap.
    var doubleTapKeyCode: UInt16? {
        switch self {
        case .doubleTapRightOption: return 61
        case .doubleTapRightShift: return 60
        case .keyCombination, .off: return nil
        }
    }
}

// MARK: - Double tap

/// Recognizes two quick, clean taps of one modifier key.
/// A tap is press + release within 300 ms with nothing else pressed; the second tap must
/// start within 400 ms of the first one ending. Anything else resets the gesture.
nonisolated struct DoubleTapDetector: Sendable {
    static let maxTapSeconds = 0.30
    static let maxGapSeconds = 0.40

    private var armed = false
    private var downAt: UInt64 = 0
    private var hasFirstTap = false
    private var firstTapUpAt: UInt64 = 0

    mutating func reset() {
        armed = false
        hasFirstTap = false
    }

    /// Feed every event. Returns true exactly when a clean double tap completes.
    mutating func feed(_ e: TikKeyEvent, target: UInt16, now: UInt64, ticksPerSecond: Double) -> Bool {
        guard e.kind == .flagsChanged, e.keyCode == target, let family = ModifierBits.family(for: target) else {
            reset()                                   // a real key, a click or another modifier
            return false
        }
        func seconds(_ from: UInt64) -> Double {
            now > from ? Double(now - from) / ticksPerSecond : 0
        }

        let device = ModifierBits.device(for: target)
        let isDown: Bool
        if let device, e.flags & ModifierBits.allDevice != 0 {
            isDown = e.flags & device != 0
        } else {
            isDown = e.flags & family != 0
        }

        if isDown {
            let allFamilies = ModifierBits.shift | ModifierBits.control | ModifierBits.option
                | ModifierBits.command | ModifierBits.function
            let otherFamilies = allFamilies & ~family
            let twinHeld = ModifierBits.twinDevice(for: target).map { e.flags & $0 != 0 } ?? false
            if e.flags & otherFamilies != 0 || twinHeld {
                reset()
                return false
            }
            if hasFirstTap && seconds(firstTapUpAt) > DoubleTapDetector.maxGapSeconds { hasFirstTap = false }
            armed = true
            downAt = now
            return false
        }

        guard armed else { return false }
        armed = false
        guard seconds(downAt) <= DoubleTapDetector.maxTapSeconds else {
            hasFirstTap = false                       // held, not tapped
            return false
        }
        if hasFirstTap && seconds(firstTapUpAt) <= DoubleTapDetector.maxGapSeconds {
            hasFirstTap = false
            return true
        }
        hasFirstTap = true
        firstTapUpAt = now
        return false
    }
}

// MARK: - Key combination rules

nonisolated enum ShortcutRules {
    static let command = UInt32(cmdKey)
    static let option = UInt32(optionKey)
    static let control = UInt32(controlKey)
    static let shift = UInt32(shiftKey)
    static let relevant = command | option | control | shift

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= command }
        if flags.contains(.option) { m |= option }
        if flags.contains(.control) { m |= control }
        if flags.contains(.shift) { m |= shift }
        return m
    }

    static func isFunctionKey(_ code: UInt16) -> Bool {
        functionKeyNames[code] != nil
    }

    /// Why a combination isn't allowed, or nil if it's fine.
    static func problem(keyCode: UInt16, modifiers: UInt32) -> String? {
        let m = modifiers & relevant
        let count = [command, option, control, shift].filter { m & $0 != 0 }.count
        let hasCommandOrControl = m & (command | control) != 0
        if keyCode == 53 { return "Escape can't be used. It cancels recording." }
        if !hasCommandOrControl {
            return "Include ⌘ or ⌃ so the shortcut can never type a character."
        }
        if count < 2 && !isFunctionKey(keyCode) {
            return "Use at least two modifiers (for example ⌃⌥T). Single-modifier shortcuts like ⌘T belong to apps."
        }
        return nil
    }

    static func label(keyCode: UInt16, modifiers: UInt32, characters: String?) -> String {
        var s = ""
        if modifiers & control != 0 { s += "⌃" }
        if modifiers & option != 0 { s += "⌥" }
        if modifiers & shift != 0 { s += "⇧" }
        if modifiers & command != 0 { s += "⌘" }
        return s + keyName(keyCode, characters: characters)
    }

    static func keyName(_ code: UInt16, characters: String?) -> String {
        if let name = functionKeyNames[code] { return name }
        switch code {
        case 49: return "Space"
        case 36: return "↩"
        case 76: return "⌤"
        case 48: return "⇥"
        case 51: return "⌫"
        case 117: return "⌦"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 115: return "↖"
        case 119: return "↘"
        case 116: return "⇞"
        case 121: return "⇟"
        default:
            let text = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return text.isEmpty ? "Key \(code)" : text
        }
    }

    private static let functionKeyNames: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    /// True if macOS itself uses this combination (System Settings › Keyboard › Keyboard Shortcuts).
    static func isUsedByMacOS(keyCode: UInt16, modifiers: UInt32) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let entries = unmanaged?.takeRetainedValue() as? [[String: Any]]
        else { return false }
        for entry in entries {
            guard (entry[kHISymbolicHotKeyEnabled as String] as? NSNumber)?.boolValue == true,
                  let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.intValue,
                  let mods = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value
            else { continue }
            if code == Int(keyCode) && mods & relevant == modifiers & relevant { return true }
        }
        return false
    }
}

// MARK: - Global hot key (Carbon)

enum HotKeyOutcome: Equatable {
    case registered
    case usedByMacOS
    case usedByAnotherApp
    case invalid(String)
    case failed(Int32)
}

/// Owns at most one registered hot key. Main thread only.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false

    var isRegistered: Bool { hotKeyRef != nil }

    func register(keyCode: UInt16, modifiers: UInt32) -> HotKeyOutcome {
        unregister()
        if let problem = ShortcutRules.problem(keyCode: keyCode, modifiers: modifiers) { return .invalid(problem) }
        if ShortcutRules.isUsedByMacOS(keyCode: keyCode, modifiers: modifiers) { return .usedByMacOS }
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: HotKeyBridge.signature, id: 1)
        let exclusive = OptionBits(1)          // kEventHotKeyExclusive: nobody else may own it
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers & ShortcutRules.relevant, id,
                                         GetEventDispatcherTarget(), exclusive, &ref)
        if status == noErr, let ref {
            hotKeyRef = ref
            return .registered
        }
        if status == -9878 { return .usedByAnotherApp }      // eventHotKeyExistsErr
        // Some systems reject the exclusive option itself; fall back to a normal registration.
        var plainRef: EventHotKeyRef?
        let retry = RegisterEventHotKey(UInt32(keyCode), modifiers & ShortcutRules.relevant, id,
                                        GetEventDispatcherTarget(), 0, &plainRef)
        if retry == noErr, let plainRef {
            hotKeyRef = plainRef
            return .registered
        }
        return retry == -9878 ? .usedByAnotherApp : .failed(retry)
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetEventDispatcherTarget(), HotKeyBridge.handler, 1, &spec, nil, nil)
        handlerInstalled = status == noErr
    }
}

/// C callback for the Carbon hot key. Built in a nonisolated context on purpose.
nonisolated enum HotKeyBridge {
    static let signature: OSType = 0x5449_4B21     // "TIK!"

    static let handler: EventHandlerUPP = { _, event, _ in
        guard let event else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID), nil,
                                       MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        guard status == noErr, hotKeyID.signature == HotKeyBridge.signature else {
            return OSStatus(eventNotHandledErr)
        }
        Task { @MainActor in AppModel.shared.toggleEnabled(fromHotkey: true) }
        return noErr
    }
}
