//
//  OnboardingView.swift
//  tik
//
//  First launch: value → privacy + permission → pick a sound → done.
//  Never traps the user: every step can move on, and permission is re-checked live.
//

import Foundation
import SwiftUI
import AppKit

enum OnboardingStep: Int, CaseIterable {
    case welcome, permission, sound, done
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    // After a relaunch for permission, pick up where the user left off.
    @State private var step: OnboardingStep = InputPermission.isGranted ? .sound : .welcome
    @State private var tryText = ""

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .permission: permission
                case .sound: sound
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 36)

            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 620, height: 500)
        .onChange(of: model.tapRunning) { _, running in
            if running && step == .permission {
                withAnimation { step = .sound }
            }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "keyboard.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text("Tik")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
            Text("Make every keystroke feel better.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("Hear it") { model.playPreview() }
                .controlSize(.large)
                .padding(.top, 6)
            Spacer()
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Let Tik hear your keyboard")
                .font(.title2.weight(.semibold))
            Text("To play sounds in every app, macOS asks you to allow **Input Monitoring**. Tik only uses which physical key moved and whether it went down or up.")
                .fixedSize(horizontal: false, vertical: true)
            DataBoundaryDiagram()
                .frame(maxWidth: .infinity)
            Text("Tik never stores what you type, never rebuilds words, never reads your clipboard and never sends anything anywhere. Password fields stay silent.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            permissionStatus
            Spacer()
        }
    }

    @ViewBuilder
    private var permissionStatus: some View {
        if model.tapRunning {
            Label("Tik can hear the keyboard.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if model.needsRelaunch {
            VStack(alignment: .leading, spacing: 8) {
                Label("Access granted. Tik needs a quick restart to finish.", systemImage: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.orange)
                Button("Relaunch Tik") { model.relaunch() }
                    .controlSize(.large)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button("Allow Keyboard Monitoring") { model.requestPermission() }
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                    Button("Open System Settings") { InputPermission.openSystemSettings() }
                        .controlSize(.large)
                }
                Text("In System Settings → Privacy & Security → Input Monitoring, switch on **tik**. This page updates by itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sound: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pick a sound")
                .font(.title2.weight(.semibold))
            Text("Click one to hear it. You can change it any time from the menu bar.")
                .foregroundStyle(.secondary)
            PackGrid(columns: 3)
            TextField("Type here to try it…", text: $tryText)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
            HStack {
                Text("Volume")
                Slider(value: model.binding(\.volume), in: 0...1)
            }
            Spacer()
        }
    }

    private var done: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
            Text("You're all set")
                .font(.title.weight(.semibold))
            Text("Tik lives in the menu bar, under the keyboard icon. Double-tap the right ⌥ Option key anywhere to turn it on or off. That gesture never reaches other apps.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Toggle("Launch Tik at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)
            .padding(.top, 8)
            Spacer()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.self) { s in
                    Circle()
                        .fill(s == step ? Color.accentColor : Color.primary.opacity(0.15))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            if step != .welcome && step != .done {
                Button("Back") { move(-1) }
            }
            switch step {
            case .welcome:
                Button("Continue") { move(1) }
                    .keyboardShortcut(.defaultAction)
            case .permission:
                Button(model.tapRunning ? "Continue" : "Skip for Now") { move(1) }
            case .sound:
                Button("Continue") { move(1) }
                    .keyboardShortcut(.defaultAction)
            case .done:
                Button("Start Typing") { finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func move(_ delta: Int) {
        let next = max(0, min(OnboardingStep.allCases.count - 1, step.rawValue + delta))
        if let s = OnboardingStep(rawValue: next) {
            withAnimation { step = s }
        }
    }

    private func finish() {
        model.completeOnboarding()
        dismissWindow(id: TikWindow.main)
    }
}
