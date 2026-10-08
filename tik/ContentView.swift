//
//  ContentView.swift
//  tik
//
//  Root of Tik's single window: onboarding on first run, settings afterwards.
//

import Foundation
import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.settings.hasCompletedOnboarding {
                SettingsView()
            } else {
                OnboardingView()
            }
        }
        // Tik is a menu-bar app. While its window is open it behaves like a normal app
        // (Dock icon, ⌘-Tab, focus), and goes back to menu-bar-only when the window closes.
        .onAppear {
            _ = NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        .onDisappear {
            _ = NSApp.setActivationPolicy(.accessory)
        }
    }
}

#Preview {
    ContentView()
        .environment(AppModel.shared)
}
