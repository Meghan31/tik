//
//  TikIntents.swift
//  tik
//
//  "Toggle Tik", "Turn Tik On" and "Turn Tik Off" as system-wide commands:
//  Spotlight, Siri, the Shortcuts app (and `shortcuts run` in Terminal),
//  and anything that can run a shortcut (Stream Deck, Raycast, automations).
//

import Foundation
import AppIntents

nonisolated struct ToggleTikIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Tik Sounds"
    static let description = IntentDescription("Turns Tik's keyboard sounds on or off. Returns whether Tik is now on.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        AppModel.shared.toggleEnabled(fromHotkey: true)
        return .result(value: AppModel.shared.settings.enabled)
    }
}

nonisolated struct TurnTikOnIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Tik Sounds On"
    static let description = IntentDescription("Turns Tik's keyboard sounds on.")

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.setEnabled(true)
        return .result()
    }
}

nonisolated struct TurnTikOffIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Tik Sounds Off"
    static let description = IntentDescription("Turns Tik's keyboard sounds off.")

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.setEnabled(false)
        return .result()
    }
}

nonisolated struct TikShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleTikIntent(),
                    phrases: ["Toggle \(.applicationName)", "Toggle \(.applicationName) sounds"],
                    shortTitle: "Toggle Tik",
                    systemImageName: "keyboard")
        AppShortcut(intent: TurnTikOnIntent(),
                    phrases: ["Turn on \(.applicationName)", "Turn \(.applicationName) on"],
                    shortTitle: "Turn Tik On",
                    systemImageName: "speaker.wave.2")
        AppShortcut(intent: TurnTikOffIntent(),
                    phrases: ["Turn off \(.applicationName)", "Turn \(.applicationName) off"],
                    shortTitle: "Turn Tik Off",
                    systemImageName: "speaker.slash")
    }
}
