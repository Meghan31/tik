//
//  Components.swift
//  tik
//

import Foundation
import SwiftUI
import AppKit

enum TikWindow {
    static let main = "main"
}

extension AppModel {
    /// Two-way binding to one settings field; writes go through `update` (persist + apply).
    func binding<T>(_ keyPath: WritableKeyPath<TikSettings, T>) -> Binding<T> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in self.update { $0[keyPath: keyPath] = newValue } }
        )
    }
}

enum PackStyle {
    static func symbol(for pack: PackInfo) -> String {
        guard pack.isBundled else { return "folder" }
        switch pack.id.components(separatedBy: ".").last ?? "" {
        case "cream": return "drop"
        case "deep": return "water.waves"
        case "crisp": return "sparkles"
        case "click": return "cursorarrow.click"
        case "soft": return "moon"
        case "retro": return "radio"
        default: return "keyboard"
        }
    }
}

extension Color {
    /// "#RRGGBB" → Color.
    init?(tikHex: String) {
        var s = tikHex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

/// A tiny keycap in the pack's color.
struct KeycapSwatch: View {
    let color: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.32), Color.white.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
                .padding(3)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5)
        }
        .frame(width: 20, height: 17)
        .shadow(color: Color.black.opacity(0.18), radius: 0.5, y: 1)
    }
}

/// Keycap swatch for packs with a color, SF Symbol otherwise.
struct PackIcon: View {
    let pack: PackInfo

    var body: some View {
        if let hex = pack.color, let color = Color(tikHex: hex) {
            KeycapSwatch(color: color)
        } else {
            Image(systemName: PackStyle.symbol(for: pack))
                .font(.system(size: 15, weight: .medium))
        }
    }
}

struct PackSection: Identifiable {
    let category: PackCategory
    let packs: [PackInfo]
    var id: PackCategory { category }
}

/// Grid of pack buttons, grouped Recorded → Synthesized → Your Packs.
/// Clicking one selects it and plays a short preview.
struct PackGrid: View {
    @Environment(AppModel.self) private var model
    var columns: Int = 3

    private var sections: [PackSection] {
        PackCategory.allCases.compactMap { category in
            let packs = model.packs.filter { $0.category == category }
            return packs.isEmpty ? nil : PackSection(category: category, packs: packs)
        }
    }

    var body: some View {
        let sections = self.sections
        VStack(alignment: .leading, spacing: 10) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 6) {
                    if sections.count > 1 {
                        Text(section.category.title.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns),
                              spacing: 6) {
                        ForEach(section.packs) { pack in
                            PackChip(pack: pack, isSelected: model.settings.packID == pack.id) {
                                model.selectPack(pack.id)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct PackChip: View {
    let pack: PackInfo
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                PackIcon(pack: pack)
                    .frame(height: 18)
                Text(pack.name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18)
                                     : Color.primary.opacity(hovering ? 0.08 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1)
            )
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(pack.summary.isEmpty ? pack.name : pack.summary)
    }
}

/// "Label ......... switch" row for places without a Form.
struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let display: (Float) -> String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            Slider(value: $value, in: range)
                .frame(width: 220)
            Text(display(value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
        }
    }
}

nonisolated enum Format {
    static func percent(_ v: Float) -> String { "\(Int((v * 100).rounded()))%" }
    static func cents(_ v: Float) -> String { "±\(Int(v.rounded())) ct" }
    static func decibels(_ v: Float) -> String { String(format: "±%.1f dB", Double(v)) }
}

/// Dismissible banner for model.notice.
struct NoticeBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let notice = model.notice {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill").foregroundStyle(Color.accentColor)
                Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    model.notice = nil
                } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.1)))
        }
    }
}

/// physical event → key code → sound. The whole data path, shown to the user.
struct DataBoundaryDiagram: View {
    var body: some View {
        HStack(spacing: 8) {
            step("hand.tap", "Key press")
            arrow
            step("number", "Key code")
            arrow
            step("waveform", "Sound")
        }
        .padding(.vertical, 6)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
    }

    private func step(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.title3)
            Text(title).font(.caption)
        }
        .frame(width: 84, height: 56)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

/// Buttons that play individual key classes through the current pack.
struct TestKey: Identifiable {
    let title: String
    let code: UInt16
    var id: UInt16 { code }
}

struct TestPad: View {
    @Environment(AppModel.self) private var model
    private let keys = [TestKey(title: "Letter", code: 0), TestKey(title: "Space", code: 49),
                        TestKey(title: "Return", code: 36), TestKey(title: "Shift", code: 56),
                        TestKey(title: "Delete", code: 51), TestKey(title: "⌘", code: 55),
                        TestKey(title: "Click", code: MouseCode.left)]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(keys) { key in
                Button(key.title) { model.playTestKey(key.code) }
                    .controlSize(.small)
            }
        }
    }
}

/// Click, then press a key combination. Escape cancels.
/// The combination is only kept if macOS agrees nobody else is using it.
struct ShortcutRecorder: View {
    @Environment(AppModel.self) private var model
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(title)
                    .monospaced()
                    .frame(minWidth: 140)
            }
            .buttonStyle(.bordered)
            .tint(recording ? Color.accentColor : nil)
            if recording {
                Button("Cancel") { stop() }
                    .buttonStyle(.borderless)
            }
        }
        .onDisappear { stop() }
    }

    private var title: String {
        if recording { return "Press shortcut…" }
        return model.settings.comboLabel.isEmpty ? "Record Shortcut" : model.settings.comboLabel
    }

    private func start() {
        guard monitor == nil else { return }
        model.pauseHotKeyForRecording()
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 {                      // Escape cancels
                stop()
                return nil
            }
            let modifiers = ShortcutRules.carbonModifiers(from: event.modifierFlags)
            model.recordKeyCombo(keyCode: event.keyCode, modifiers: modifiers,
                                 characters: event.charactersIgnoringModifiers)
            stop()
            return nil                                    // swallow it: it was meant for Tik
        }
    }

    private func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        if recording {
            recording = false
            model.resumeHotKeyAfterRecording()
        }
    }
}
