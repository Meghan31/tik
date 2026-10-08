//
//  KeyMap.swift
//  tik
//
//  Physical key model: which sound group a key uses, and where it sits on the board.
//  Keys are identified by macOS virtual key codes (physical positions), never by characters,
//  so switching to Dvorak or another input language does not change how a key sounds.
//

import Foundation

/// Sound groups. Raw values are the group names used in pack manifests.
nonisolated enum KeyClass: String, CaseIterable, Codable, Sendable {
    case alpha, modifier, function, nav, wide, backspace, enter, space, mouse

    /// Group to borrow from when a pack does not provide this one.
    var fallback: KeyClass? {
        switch self {
        case .alpha, .mouse: return nil
        case .modifier, .function, .nav, .wide: return .alpha
        case .backspace, .enter, .space: return .wide
        }
    }

    var displayName: String {
        switch self {
        case .alpha: return "Letters & numbers"
        case .modifier: return "Modifiers"
        case .function: return "Esc & function row"
        case .nav: return "Arrows & navigation"
        case .wide: return "Tab, Caps, Shift"
        case .backspace: return "Delete"
        case .enter: return "Return"
        case .space: return "Space"
        case .mouse: return "Mouse"
        }
    }
}

/// Pseudo key codes for mouse buttons. Real key codes are always < 0x100.
nonisolated enum MouseCode {
    static let left: UInt16 = 0x200
    static let right: UInt16 = 0x201
    static let other: UInt16 = 0x202
    /// Size of any table indexed by key code (covers keys + mouse buttons).
    static let tableSize = 0x203
}

/// Normalized key position: x is -1 (left edge) ... +1 (right edge), y is -1 (bottom row) ... +1 (function row).
nonisolated struct KeyPosition: Sendable, Equatable {
    let x: Float
    let y: Float
}

nonisolated enum KeyMap {

    static func keyClass(for code: UInt16) -> KeyClass {
        if code >= 0x200 { return .mouse }
        switch code {
        case 49: return .space
        case 36, 76, 52: return .enter
        case 51: return .backspace
        case 48, 57, 56, 60: return .wide
        case 54, 55, 58, 59, 61, 62, 63, 179: return .modifier
        case 53, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
             105, 107, 113, 106, 64, 79, 80, 90:
            return .function
        case 123, 124, 125, 126, 115, 119, 116, 121, 117, 114: return .nav
        default: return .alpha
        }
    }

    static func position(for code: UInt16) -> KeyPosition {
        if let p = table[code] { return p }
        if code >= 0x200 { return KeyPosition(x: 0.55, y: -1) }          // the mouse usually sits to the right
        if (65...92).contains(code) { return KeyPosition(x: 1, y: -0.2) } // numeric keypad
        if [105, 107, 113, 106, 64, 79, 80, 90].contains(code) { return KeyPosition(x: 0.95, y: 1) } // F13+
        return KeyPosition(x: 0, y: 0)
    }

    /// Stable per-key pitch personality in cents, before the user's "key character" amount.
    /// Real boards never sound identical key-to-key, but each key sounds consistent with itself.
    static func characterCents(for code: UInt16) -> Float {
        let h = UInt32(code) &* 2_654_435_761
        let u = Float(h >> 8) / Float(1 << 24) * 2 - 1
        return u * 18 + position(for: code).y * 6
    }

    /// Call once at startup so the table is built off the real-time path.
    static func warmUp() {
        _ = table.count
    }

    private static let table: [UInt16: KeyPosition] = {
        var t: [UInt16: KeyPosition] = [:]
        func row(_ y: Float, _ items: [(UInt16, Float)]) {
            for (code, x) in items { t[code] = KeyPosition(x: x, y: y) }
        }
        // Esc + function row
        row(1.0, [(53, -0.95), (122, -0.80), (120, -0.67), (99, -0.53), (118, -0.40), (96, -0.27), (97, -0.13),
                  (98, 0.0), (100, 0.13), (101, 0.27), (109, 0.40), (103, 0.53), (111, 0.67)])
        // Number row (10 = ISO § key)
        row(0.6, [(50, -0.93), (10, -0.93), (18, -0.80), (19, -0.67), (20, -0.53), (21, -0.40), (23, -0.27),
                  (22, -0.13), (26, 0.0), (28, 0.13), (25, 0.27), (29, 0.40), (27, 0.53), (24, 0.67), (51, 0.88)])
        // Top letter row
        row(0.2, [(48, -0.88), (12, -0.73), (13, -0.60), (14, -0.47), (15, -0.33), (17, -0.20), (16, -0.07),
                  (32, 0.07), (34, 0.20), (31, 0.33), (35, 0.47), (33, 0.60), (30, 0.73), (42, 0.90)])
        // Home row
        row(-0.2, [(57, -0.86), (0, -0.69), (1, -0.56), (2, -0.43), (3, -0.29), (5, -0.16), (4, -0.03),
                   (38, 0.10), (40, 0.23), (37, 0.37), (41, 0.50), (39, 0.63), (36, 0.85)])
        // Bottom letter row
        row(-0.6, [(56, -0.82), (6, -0.62), (7, -0.49), (8, -0.36), (9, -0.22), (11, -0.09), (45, 0.04),
                   (46, 0.17), (43, 0.30), (47, 0.44), (44, 0.57), (60, 0.80)])
        // Modifier / space row + arrows
        row(-1.0, [(63, -0.95), (179, -0.95), (59, -0.83), (58, -0.70), (55, -0.55), (49, 0.0), (54, 0.50),
                   (61, 0.65), (62, 0.72), (123, 0.75), (125, 0.85), (124, 0.95)])
        t[126] = KeyPosition(x: 0.85, y: -0.8)
        // Navigation cluster on full-size keyboards
        for code: UInt16 in [114, 115, 116, 117, 119, 121] { t[code] = KeyPosition(x: 0.95, y: 0.4) }
        return t
    }()
}
