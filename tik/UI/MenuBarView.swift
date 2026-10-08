//
//  MenuBarView.swift
//  tik
//
//  The menu-bar panel. Opens instantly: no network, no loading, just state.
//

import Foundation
import SwiftUI
import AppKit

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.needsAttention {
                attentionCard
            }

            NoticeBanner()

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Sound")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                PackGrid(columns: 3)
            }

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Slider(value: model.binding(\.volume), in: 0...1)
                    .controlSize(.small)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Divider()

            VStack(spacing: 7) {
                SwitchRow(title: "Release sounds", isOn: model.binding(\.releaseSounds))
                SwitchRow(title: "Modifier keys", isOn: model.binding(\.modifierSounds))
                SwitchRow(title: "Mouse clicks", isOn: model.binding(\.mouseSounds))
            }
            .font(.callout)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Button {
                    model.openPackBuilder()
                    showMainWindow()
                } label: {
                    Label("Make Your Own Pack…", systemImage: "waveform.badge.plus")
                }
                .buttonStyle(.borderless)
                if !model.toggleHint.isEmpty {
                    Text("\(model.toggleHint.prefix(1).uppercased() + model.toggleHint.dropFirst()) to turn Tik on or off")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            Divider()

            HStack {
                Button("Settings…") { showMainWindow() }
                Spacer()
                Button("Quit Tik") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(14)
        .frame(width: 300)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tik")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(model.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("Enabled", isOn: Binding(
                get: { model.settings.enabled },
                set: { _ in model.toggleEnabled() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
    }

    private var attentionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.needsRelaunch ? "One more step" : "Keyboard access needed",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text(model.needsRelaunch
                 ? "macOS granted access, but Tik has to restart before it can hear the keyboard."
                 : "Tik needs Input Monitoring to hear key presses. It never records what you type.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.needsRelaunch {
                Button("Relaunch Tik") { model.relaunch() }
                    .controlSize(.small)
            } else {
                Button("Set Up…") { showMainWindow() }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.12)))
    }

    private func showMainWindow() {
        openWindow(id: TikWindow.main)
        NSApp.activate()
    }
}
