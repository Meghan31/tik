//
//  SettingsView.swift
//  tik
//

import Foundation
import SwiftUI
import AppKit

enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case sound, behavior, packs, general, diagnostics, privacy, about

    var id: SettingsPane { self }

    var title: String {
        switch self {
        case .sound: return "Sound"
        case .behavior: return "Behavior"
        case .packs: return "Sound Packs"
        case .general: return "General"
        case .diagnostics: return "Diagnostics"
        case .privacy: return "Privacy"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .sound: return "speaker.wave.2"
        case .behavior: return "keyboard"
        case .packs: return "square.stack.3d.up"
        case .general: return "gearshape"
        case .diagnostics: return "stethoscope"
        case .privacy: return "hand.raised"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var pane: SettingsPane? = .sound

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { item in
                Label(item.title, systemImage: item.symbol)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
        } detail: {
            VStack(spacing: 0) {
                if model.needsAttention || model.notice != nil {
                    VStack(spacing: 8) {
                        if model.needsAttention { PermissionBanner() }
                        NoticeBanner()
                    }
                    .padding([.horizontal, .top], 20)
                }
                detail(for: pane ?? .sound)
            }
            .navigationTitle((pane ?? .sound).title)
        }
        .frame(minWidth: 780, idealWidth: 800, minHeight: 560, idealHeight: 600)
        .sheet(isPresented: Binding(get: { model.showPackBuilder }, set: { model.showPackBuilder = $0 })) {
            PackBuilderView()
                .environment(model)
        }
        .onAppear { consumePendingPane() }
        .onChange(of: model.pendingPane) { _, _ in consumePendingPane() }
    }

    private func consumePendingPane() {
        if let requested = model.pendingPane {
            pane = requested
            model.pendingPane = nil
        }
    }

    @ViewBuilder
    private func detail(for pane: SettingsPane) -> some View {
        switch pane {
        case .sound: SoundPane()
        case .behavior: BehaviorPane()
        case .packs: PacksPane()
        case .general: GeneralPane()
        case .diagnostics: DiagnosticsPane()
        case .privacy: PrivacyPane()
        case .about: AboutPane()
        }
    }
}

struct PermissionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(model.statusLine).font(.callout)
            Spacer()
            if model.needsRelaunch {
                Button("Relaunch Tik") { model.relaunch() }
            } else {
                Button("Allow Keyboard Monitoring…") { model.requestPermission() }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}

// MARK: - Sound

struct SoundPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                PackGrid(columns: 6)
                HStack {
                    Text(model.packs.first(where: { $0.id == model.settings.packID })?.summary ?? "")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Preview") { model.playPreview() }
                }
            } header: {
                Text("Pack")
            }

            Section("Level") {
                SliderRow(title: "Volume", value: model.binding(\.volume), range: 0...1, display: Format.percent)
                SliderRow(title: "Key release", value: model.binding(\.releaseVolume), range: 0...1,
                          display: Format.percent)
            }

            Section {
                SliderRow(title: "Pitch variation", value: model.binding(\.pitchVariation), range: 0...50,
                          display: Format.cents)
                SliderRow(title: "Loudness variation", value: model.binding(\.gainVariation), range: 0...3,
                          display: Format.decibels)
                SliderRow(title: "Key character", value: model.binding(\.keyCharacter), range: 0...1,
                          display: Format.percent)
                SliderRow(title: "Stereo width", value: model.binding(\.spatialWidth), range: 0...1,
                          display: Format.percent)
            } header: {
                Text("Realism")
            } footer: {
                Text("Variation keeps repeated keys from sounding machine-gunned. Key character gives each physical key its own consistent voice, the way real boards do. Stereo width places keys left to right as they sit on the keyboard.")
                    .foregroundStyle(.secondary)
            }

            Section("Try it") {
                TestPad()
                Text("Or just type anywhere. Tik reacts system-wide.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Reset Tuning to Defaults") { model.update { $0.resetTuning() } }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Behavior

struct BehaviorPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Sounds") {
                Toggle("Key release sounds", isOn: model.binding(\.releaseSounds))
                Toggle("Modifier keys (⇧ ⌃ ⌥ ⌘ fn ⇪)", isOn: model.binding(\.modifierSounds))
                Toggle("Mouse clicks", isOn: model.binding(\.mouseSounds))
            }

            Section {
                Picker("Held keys", selection: model.binding(\.repeatMode)) {
                    ForEach(RepeatMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            } footer: {
                Text("“First press only” matches a real keyboard: holding a key makes one press sound, then the release.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Ignore keystrokes generated by apps", isOn: model.binding(\.ignoreSyntheticEvents))
            } footer: {
                Text("Text expanders, automation and remote-control tools post keystrokes that never touched your keyboard. Turn this on to keep them silent.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Turn Tik on or off with", selection: model.binding(\.toggleShortcut)) {
                    ForEach(ToggleShortcut.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                if model.settings.toggleShortcut == .keyCombination {
                    LabeledContent("Key combination") {
                        ShortcutRecorder()
                    }
                }
                Label(model.shortcutStatus,
                      systemImage: model.shortcutIsProblem ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                    .foregroundStyle(model.shortcutIsProblem ? Color.orange : Color.green)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("On/off command")
            } footer: {
                Text("Works in every app, even while Tik is off. Tik plays a tiny tick when it turns back on. You can also say or search “Toggle Tik” in Spotlight, Siri or the Shortcuts app.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Packs

struct PacksPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "waveform.badge.plus")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Use your own sounds").font(.headline)
                        Text("Upload clicks, or record yourself pressing a key a few times. Tik finds every press and release and builds a pack.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Make Your Own Pack…") { model.showPackBuilder = true }
                        .controlSize(.large)
                }
                .padding(.vertical, 4)
            }

            Section("Installed") {
                ForEach(model.packs) { pack in
                    PackRow(pack: pack)
                }
            }

            Section {
                HStack {
                    Button("Import Pack Folder…") { model.importPack() }
                    Button("Make Editable Copy") { model.exportActivePack() }
                        .help("Writes the current pack as WAV files + manifest.json you can edit or replace")
                    Spacer()
                    Button("Show Packs Folder") { model.revealPacksFolder() }
                    Button("Reload") { model.reloadPacks() }
                }
            } footer: {
                Text("Packs are just audio files and a manifest. Nothing in a pack is ever run.")
                    .foregroundStyle(.secondary)
            }

            Section("Pack format") {
                Text("""
                MyPack/
                  manifest.json
                  sounds/alpha/down-01.wav, up-01.wav …
                  sounds/space/…  enter/…  backspace/…  wide/…  modifier/…  mouse/…

                {
                  "id": "com.you.mypack",
                  "name": "My Pack",
                  "groups": {
                    "alpha": { "down": ["sounds/alpha/down-01.wav"], "up": ["sounds/alpha/up-01.wav"] },
                    "space": { "down": ["sounds/space/down-01.wav"] }
                  },
                  "mapping": { "49": "space" }
                }
                """)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                Text("Groups: alpha, modifier, function, nav, wide, backspace, enter, space, mouse. Missing groups fall back sensibly (space → wide → alpha). Use 8+ variants per group. Tik trims leading silence and converts everything to 48 kHz mono on import. Limits: 3 s per clip, 5 MB per file, 600 clips.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PackRow: View {
    @Environment(AppModel.self) private var model
    let pack: PackInfo

    var body: some View {
        HStack(spacing: 12) {
            PackIcon(pack: pack)
                .frame(width: 22)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pack.name).font(.body.weight(.medium))
                    Text(pack.category.badge)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                if !pack.summary.isEmpty {
                    Text(pack.summary).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.settings.packID == pack.id {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
            Button("Use") { model.selectPack(pack.id) }
                .controlSize(.small)
            if !pack.isBundled {
                Button {
                    model.deletePack(pack)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Move this pack to the Trash")
            }
        }
    }
}

// MARK: - General

struct GeneralPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Toggle("Tik is on", isOn: model.binding(\.enabled))
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
            }

            Section {
                Picker("Audio buffer", selection: model.binding(\.latencyMode)) {
                    ForEach(LatencyMode.allCases, id: \.self) { mode in
                        Text("\(mode.label) (\(mode.bufferFrames) frames)").tag(mode)
                    }
                }
            } header: {
                Text("Latency")
            } footer: {
                Text("Smaller buffers make sounds land sooner but wake the CPU more often. Balanced is about 5 ms at 48 kHz. Bluetooth headphones add their own delay that no app can remove.")
                    .foregroundStyle(.secondary)
            }

            Section("Keyboard access") {
                LabeledContent("Input Monitoring") {
                    Text(model.permissionGranted ? "Allowed" : "Not allowed")
                        .foregroundStyle(model.permissionGranted ? Color.green : Color.orange)
                }
                LabeledContent("Keyboard listener") {
                    Text(model.tapRunning ? "Running" : (model.needsRelaunch ? "Needs relaunch" : "Stopped"))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Open System Settings") { InputPermission.openSystemSettings() }
                    Button("Check Again") { model.checkPermission() }
                    if model.needsRelaunch {
                        Button("Relaunch Tik") { model.relaunch() }
                    }
                }
            }

            Section {
                Button("Show Welcome Again") { model.update { $0.hasCompletedOnboarding = false } }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Diagnostics

struct DiagnosticsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let d = model.diagnostics()
            Form {
                Section("Input") {
                    row("Input permission", d.permissionGranted ? "Granted" : "Not granted")
                    row("Event tap", d.tapRunning ? (d.tapEnabled ? "Running" : "Disabled by macOS") : "Not running")
                    row("Timeout recoveries", "\(d.tapRecoveries)")
                    row("Secure input", d.secureInput ? "On (Tik is silent while a password field has focus)" : "Off")
                    row("Events seen", "\(d.counters.events)")
                    row("Sounds played", "\(d.counters.sounds)")
                    row("Ignored (app-generated)", "\(d.counters.ignoredSynthetic)")
                }
                Section("Audio") {
                    row("Engine", d.output.running ? "Running" : "Stopped")
                    if let error = d.output.lastError { row("Last error", error) }
                    row("Output device", d.output.deviceName + (d.output.isBluetooth ? " (Bluetooth)" : ""))
                    row("Sample rate", "\(Int(d.output.sampleRate)) Hz")
                    row("IO buffer", "\(d.output.bufferFrames) frames")
                    row("Device latency", ms(d.output.presentationLatency * 1000))
                    row("Output path (buffer + device)", ms(d.output.estimatedOutputMs))
                    row("Engine starts", "\(d.output.rebuilds)")
                }
                Section {
                    row("Average", ms(d.mixer.averageMs))
                    row("Worst", ms(d.mixer.maxMs))
                    row("Measured sounds", "\(d.mixer.commands)")
                    row("Active voices", "\(d.mixer.activeVoices) / \(VoiceMixer.maxVoices)")
                    row("Dropped", "\(d.mixer.dropped)")
                } header: {
                    Text("Tik latency (key event → audio thread)")
                } footer: {
                    Text("Time from the key event reaching Tik to its sound starting on the audio thread. What you hear is this plus the output path above.")
                        .foregroundStyle(.secondary)
                }
                Section("Pack") {
                    row("Loaded", d.packName)
                    row("Clips", "\(d.packClips) · \(String(format: "%.1f", d.packSeconds)) s")
                    row("Memory", "\(d.packMemoryKB) KB")
                }
                Section {
                    HStack {
                        Button("Copy Diagnostics") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.diagnosticsReport(), forType: .string)
                        }
                        Button("Reset Latency Stats") { model.engine.mixer.resetStats() }
                        Spacer()
                        Text("Contains no keystrokes or typing history.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func ms(_ v: Double) -> String {
        String(format: "%.2f ms", v)
    }
}

// MARK: - Privacy

struct PrivacyPane: View {
    var body: some View {
        Form {
            Section {
                DataBoundaryDiagram()
                    .frame(maxWidth: .infinity)
            } footer: {
                Text("That's the entire path. Tik never turns key codes into characters.")
                    .foregroundStyle(.secondary)
            }
            Section("Tik never") {
                bullet("Saves, reconstructs or displays what you type")
                bullet("Reads your clipboard, windows, documents or URLs")
                bullet("Keeps a history of key events. Each one is forgotten once its sound is chosen")
                bullet("Connects to the internet. There's no account, analytics or telemetry")
                bullet("Tries to get around Secure Input. Password fields stay silent, by design")
            }
            Section("What Tik keeps") {
                bullet("Your settings, stored on this Mac")
                bullet("Event and sound counts for Diagnostics, held in memory only")
                bullet("Custom packs you import, in Tik's own Packs folder")
            }
        }
        .formStyle(.grouped)
    }

    private func bullet(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.shield")
    }
}

// MARK: - About

struct AboutPane: View {
    var body: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "keyboard.fill")
                .font(.system(size: 52))
                .foregroundStyle(Color.accentColor)
            Text("Tik")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
            Text("Version \(version) (\(build))")
                .foregroundStyle(.secondary)
            Text("Makes every keystroke feel tactile with immediate, realistic sound.")
                .multilineTextAlignment(.center)
            Text("All bundled sounds are original, synthesized by Tik's physical keyboard model: impact modes, case resonance, stabilizer rattle and release ticks. No recordings or third-party assets are used.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
