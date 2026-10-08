//
//  tikApp.swift
//  tik
//
//  Created by Meghasrivardhan Pulakhandam on 10/7/26.
//

import Foundation
import SwiftUI
import AppKit

@main
struct TikApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Window("Tik", id: TikWindow.main) {
            ContentView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(model.shouldShowWindowAtLaunch ? .presented : .suppressed)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }
}
