//
//  InputPermission.swift
//  tik
//
//  Input Monitoring (TCC "ListenEvent") permission, using public Core Graphics APIs only.
//

import Foundation
import AppKit
import CoreGraphics

enum InputPermission {
    static var isGranted: Bool {
        CGPreflightListenEventAccess()
    }

    /// Shows the system prompt the first time; afterwards macOS just returns the current state.
    @discardableResult
    static func request() -> Bool {
        CGRequestListenEventAccess()
    }

    static func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }
}
