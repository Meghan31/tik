//
//  KeyEvent.swift
//  tik
//
//  The privacy-safe event model plus the key state machine.
//  An event carries a physical key code, a phase and modifier flags. It never carries
//  characters, strings, the focused app, or anything that could rebuild what was typed.
//

import Foundation

nonisolated enum KeyPhase: UInt8, Sendable {
    case down
    case up
}

nonisolated enum TikEventKind: UInt8, Sendable {
    case keyDown
    case keyUp
    case flagsChanged
    case mouseDown
    case mouseUp
}

nonisolated struct TikKeyEvent: Sendable, Equatable {
    var kind: TikEventKind
    var keyCode: UInt16
    var isRepeat: Bool = false
    var flags: UInt64 = 0
}

nonisolated enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case firstOnly
    case everyRepeat

    var label: String {
        switch self {
        case .firstOnly: return "First press only"
        case .everyRepeat: return "Every repeat"
        }
    }
}

/// Modifier flag bits (from CGEventFlags / IOLLEvent.h), kept as raw values so this file needs no CoreGraphics.
nonisolated enum ModifierBits {
    static let capsLock: UInt64 = 0x0001_0000
    static let shift: UInt64 = 0x0002_0000
    static let control: UInt64 = 0x0004_0000
    static let option: UInt64 = 0x0008_0000
    static let command: UInt64 = 0x0010_0000
    static let function: UInt64 = 0x0080_0000

    // Device-dependent (left/right) bits
    static let leftControl: UInt64 = 0x0000_0001
    static let leftShift: UInt64 = 0x0000_0002
    static let rightShift: UInt64 = 0x0000_0004
    static let leftCommand: UInt64 = 0x0000_0008
    static let rightCommand: UInt64 = 0x0000_0010
    static let leftOption: UInt64 = 0x0000_0020
    static let rightOption: UInt64 = 0x0000_0040
    static let rightControl: UInt64 = 0x0000_2000
    static let allDevice: UInt64 = 0x0000_207F

    /// Generic family bit for a modifier key code.
    static func family(for code: UInt16) -> UInt64? {
        switch code {
        case 56, 60: return shift
        case 59, 62: return control
        case 58, 61: return option
        case 55, 54: return command
        case 63, 179: return function
        default: return nil
        }
    }

    /// Left/right specific bit for a modifier key code, when macOS reports one.
    static func device(for code: UInt16) -> UInt64? {
        switch code {
        case 56: return leftShift
        case 60: return rightShift
        case 59: return leftControl
        case 62: return rightControl
        case 58: return leftOption
        case 61: return rightOption
        case 55: return leftCommand
        case 54: return rightCommand
        default: return nil
        }
    }

    /// Device bit of the same modifier on the other side of the keyboard.
    static func twinDevice(for code: UInt16) -> UInt64? {
        switch code {
        case 56: return rightShift
        case 60: return leftShift
        case 59: return rightControl
        case 62: return leftControl
        case 58: return rightOption
        case 61: return leftOption
        case 55: return rightCommand
        case 54: return leftCommand
        default: return nil
        }
    }
}

/// Tracks which keys are physically down and turns raw events into sound phases.
/// Only ever touched under SoundEngine's lock. Uses a fixed bitset: no allocation per event.
nonisolated struct KeyState {
    private var bits = [UInt64](repeating: 0, count: (MouseCode.tableSize + 63) / 64)

    func isDown(_ code: UInt16) -> Bool {
        let i = Int(code)
        guard i < MouseCode.tableSize else { return false }
        return bits[i >> 6] & (1 << UInt64(i & 63)) != 0
    }

    mutating func set(_ code: UInt16, _ down: Bool) {
        let i = Int(code)
        guard i < MouseCode.tableSize else { return }
        if down {
            bits[i >> 6] |= (1 << UInt64(i & 63))
        } else {
            bits[i >> 6] &= ~(1 << UInt64(i & 63))
        }
    }

    mutating func reset() {
        for i in bits.indices { bits[i] = 0 }
    }

    /// Returns the phase this event should sound as, or nil for silence.
    mutating func process(_ e: TikKeyEvent, repeatMode: RepeatMode) -> KeyPhase? {
        switch e.kind {
        case .keyDown:
            if e.isRepeat {
                return repeatMode == .everyRepeat ? .down : nil
            }
            set(e.keyCode, true)
            return .down
        case .keyUp:
            set(e.keyCode, false)
            return .up
        case .mouseDown:
            set(e.keyCode, true)
            return .down
        case .mouseUp:
            set(e.keyCode, false)
            return .up
        case .flagsChanged:
            return modifierPhase(code: e.keyCode, flags: e.flags)
        }
    }

    private mutating func modifierPhase(code: UInt16, flags: UInt64) -> KeyPhase? {
        // Caps Lock reports a lock toggle, not press/release. One sound per press.
        if code == 57 { return .down }
        guard let family = ModifierBits.family(for: code) else { return nil }

        let wasDown = isDown(code)
        let nowDown: Bool
        if flags & family == 0 {
            nowDown = false                                   // whole family released
        } else if let device = ModifierBits.device(for: code), flags & ModifierBits.allDevice != 0 {
            nowDown = flags & device != 0                     // left/right bit is authoritative
        } else {
            nowDown = !wasDown                                // no side info (e.g. Fn): toggle
        }
        guard nowDown != wasDown else { return nil }          // duplicate / missed event: stay quiet
        set(code, nowDown)
        return nowDown ? .down : .up
    }
}
