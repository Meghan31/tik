//
//  AppModel.swift
//  tik
//
//  App-level state and lifecycle. Lives on the main actor; everything latency-critical
//  is delegated to SoundEngine / EventTap / VoiceMixer, which run off the main thread.
//

import Foundation
import AppKit
import Observation
import ServiceManagement
import CoreGraphics
import Carbon

struct DiagnosticsSnapshot {
    var output: OutputInfo
    var mixer: MixerStats
    var counters: EngineCounters
    var permissionGranted: Bool
    var tapRunning: Bool
    var tapEnabled: Bool
    var tapRecoveries: Int
    var secureInput: Bool
    var packName: String
    var packClips: Int
    var packSeconds: Double
    var packMemoryKB: Int
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var settings: TikSettings
    private(set) var permissionGranted: Bool
    private(set) var tapRunning = false
    private(set) var needsRelaunch = false
    private(set) var audioRunning = false
    private(set) var packs: [PackInfo] = []
    private(set) var activePackID: String?
    private(set) var activePackName = ""
    private(set) var isLoadingPack = false
    private(set) var launchAtLogin = false
    private(set) var shortcutStatus = ""
    private(set) var shortcutIsProblem = false
    private(set) var isAuditioning = false
    var showPackBuilder = false
    var pendingPane: SettingsPane?
    var notice: String?

    let engine: SoundEngine
    let audio: AudioOutput
    let tap: EventTap
    let hotKey = GlobalHotKey()

    @ObservationIgnored private var permissionTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var previewing = false
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewAfterLoad = false
    @ObservationIgnored private var started = false

    private init() {
        let engine = SoundEngine()
        self.engine = engine
        self.audio = AudioOutput(mixer: engine.mixer)
        self.tap = EventTap(engine: engine)
        self.settings = SettingsStore.load()
        self.permissionGranted = InputPermission.isGranted
    }

    // MARK: Derived state

    var needsAttention: Bool { !permissionGranted || needsRelaunch || !tapRunning }

    var menuBarSymbol: String {
        if needsAttention { return "exclamationmark.triangle" }
        return settings.enabled ? "keyboard.fill" : "keyboard"
    }

    var statusLine: String {
        if !permissionGranted { return "Needs Input Monitoring permission" }
        if needsRelaunch { return "Relaunch Tik to finish setup" }
        if !tapRunning { return "Waiting for keyboard access" }
        if !settings.enabled {
            return toggleHint.isEmpty ? "Off" : "Off · \(toggleHint) to turn on"
        }
        if isAuditioning { return "On · trying your new pack" }
        if isLoadingPack { return "Loading sounds…" }
        if !audioRunning { return "No audio output" }
        return "On · \(activePackName)"
    }

    /// Short description of the on/off command, e.g. "double-tap right ⌥".
    var toggleHint: String {
        switch settings.toggleShortcut {
        case .doubleTapRightOption: return "double-tap right ⌥"
        case .doubleTapRightShift: return "double-tap right ⇧"
        case .keyCombination: return hotKey.isRegistered ? "press \(settings.comboLabel)" : ""
        case .off: return ""
        }
    }

    var shouldShowWindowAtLaunch: Bool {
        !settings.hasCompletedOnboarding || !InputPermission.isGranted
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        // Unit tests run inside the app; don't grab the keyboard or the audio device there.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }

        engine.onToggleHotkey = {
            Task { @MainActor in AppModel.shared.toggleEnabled(fromHotkey: true) }
        }
        engine.apply(settings)
        audio.bufferFrames = settings.latencyMode.bufferFrames
        audio.onChange = { [weak self] in self?.syncAudioState() }

        reloadPacks()
        migrateToRecordedDefault()
        loadActivePack()
        refreshLaunchAtLogin()
        applyToggleShortcut()
        installSystemObservers()
        checkPermission()
        if !tapRunning { startPermissionPolling() }
    }

    // MARK: Settings

    func update(_ change: (inout TikSettings) -> Void) {
        var next = settings
        change(&next)
        next.sanitize()
        guard next != settings else { return }
        let previous = settings
        settings = next
        SettingsStore.save(next)
        engine.apply(next)

        if previous.packID != next.packID { loadActivePack() }
        if previous.latencyMode != next.latencyMode {
            audio.bufferFrames = next.latencyMode.bufferFrames
            if audio.isRunning { audio.rebuildSoon(after: 0.05) }
        }
        if previous.enabled != next.enabled { applyAudioState() }
        if previous.toggleShortcut != next.toggleShortcut
            || previous.comboKeyCode != next.comboKeyCode
            || previous.comboModifiers != next.comboModifiers {
            applyToggleShortcut()
        }
    }

    func setEnabled(_ on: Bool) {
        update { $0.enabled = on }
    }

    func toggleEnabled(fromHotkey: Bool = false) {
        update { $0.enabled.toggle() }
        if fromHotkey && settings.enabled {
            // A tiny confirmation so you know the hotkey landed.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(40))
                self?.engine.play(keyCode: 40, phase: .down)
                try? await Task.sleep(for: .milliseconds(70))
                self?.engine.play(keyCode: 40, phase: .up)
            }
        }
    }

    func completeOnboarding() {
        update { $0.hasCompletedOnboarding = true }
    }

    // MARK: On/off command

    func applyToggleShortcut() {
        hotKey.unregister()
        shortcutIsProblem = false
        switch settings.toggleShortcut {
        case .doubleTapRightOption:
            shortcutStatus = "Tap the right ⌥ Option key twice, quickly. Option on its own never types anything, so no app can react to it."
        case .doubleTapRightShift:
            shortcutStatus = "Tap the right ⇧ Shift key twice, quickly. Shift on its own never types anything, so no app can react to it."
        case .off:
            shortcutStatus = "Use the switch in the menu bar, or “Toggle Tik” in Spotlight or Shortcuts."
        case .keyCombination:
            guard settings.comboKeyCode >= 0 else {
                shortcutStatus = "Record a key combination below."
                shortcutIsProblem = true
                return
            }
            let outcome = hotKey.register(keyCode: UInt16(settings.comboKeyCode), modifiers: settings.comboModifiers)
            describe(outcome, label: settings.comboLabel)
        }
    }

    private func describe(_ outcome: HotKeyOutcome, label: String) {
        switch outcome {
        case .registered:
            shortcutStatus = "\(label) is reserved for Tik. macOS sends it only to Tik, so other apps never see it."
            shortcutIsProblem = false
        case .usedByMacOS:
            shortcutStatus = "macOS already uses \(label) (System Settings › Keyboard › Keyboard Shortcuts). Pick another."
            shortcutIsProblem = true
        case .usedByAnotherApp:
            shortcutStatus = "Another app has already claimed \(label). Pick another."
            shortcutIsProblem = true
        case .invalid(let reason):
            shortcutStatus = reason
            shortcutIsProblem = true
        case .failed(let status):
            shortcutStatus = "macOS couldn't register \(label) (error \(status)). Pick another."
            shortcutIsProblem = true
        }
    }

    /// Called by the shortcut recorder. Only saves the combination if macOS accepts it.
    func recordKeyCombo(keyCode: UInt16, modifiers: UInt32, characters: String?) {
        let label = ShortcutRules.label(keyCode: keyCode, modifiers: modifiers, characters: characters)
        let outcome = hotKey.register(keyCode: keyCode, modifiers: modifiers)
        guard outcome == .registered else {
            describe(outcome, label: label)
            // Keep whatever worked before.
            if settings.comboKeyCode >= 0 {
                let previous = settings.comboLabel
                let message = shortcutStatus
                _ = hotKey.register(keyCode: UInt16(settings.comboKeyCode), modifiers: settings.comboModifiers)
                shortcutStatus = message + " Still using \(previous)."
            }
            return
        }
        update {
            $0.toggleShortcut = .keyCombination
            $0.comboKeyCode = Int(keyCode)
            $0.comboModifiers = modifiers
            $0.comboLabel = label
        }
        applyToggleShortcut()
    }

    /// While recording, the current hot key must not fire.
    func pauseHotKeyForRecording() {
        hotKey.unregister()
    }

    func resumeHotKeyAfterRecording() {
        guard settings.toggleShortcut == .keyCombination, settings.comboKeyCode >= 0, !hotKey.isRegistered else { return }
        applyToggleShortcut()
    }

    // MARK: Pack builder

    func openPackBuilder() {
        pendingPane = .packs
        showPackBuilder = true
    }

    /// Temporarily plays an unsaved pack, so you can type with it before saving.
    func audition(_ bank: SoundBank) {
        isAuditioning = true
        engine.setBank(bank)
    }

    func endAudition() {
        guard isAuditioning else { return }
        isAuditioning = false
        loadActivePack()
    }

    func didSaveBuiltPack(id: String) {
        isAuditioning = false
        reloadPacks()
        notice = "Saved your pack. It's in Sound Packs, and you can switch to it any time."
        selectPack(id, preview: false)
    }

    // MARK: Permission + event tap

    func requestPermission() {
        let alreadyAsked = UserDefaults.standard.bool(forKey: "tik.permission.asked")
        UserDefaults.standard.set(true, forKey: "tik.permission.asked")
        if InputPermission.request() {
            checkPermission()
        } else if alreadyAsked {
            InputPermission.openSystemSettings()
        }
        startPermissionPolling()
    }

    func checkPermission() {
        let granted = InputPermission.isGranted
        if granted != permissionGranted { permissionGranted = granted }
        if granted {
            if !tapRunning {
                tapRunning = tap.start()
                needsRelaunch = !tapRunning
            }
        } else if tapRunning {
            tap.stop()
            tapRunning = false
        }
        if tapRunning { stopPermissionPolling() }
        applyAudioState()
    }

    private func startPermissionPolling() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.checkPermission()
            }
        }
    }

    private func stopPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    /// Input Monitoring sometimes only takes effect for a fresh process.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    // MARK: Audio

    private func applyAudioState() {
        let wanted = (settings.enabled && tapRunning) || previewing
        if wanted { audio.start() } else { audio.stop() }
        syncAudioState()
    }

    private func syncAudioState() {
        let running = audio.isRunning
        engine.setAudible(running)
        if audioRunning != running { audioRunning = running }
    }

    /// Plays a short typing phrase with the active pack (works even while Tik is off).
    func playPreview() {
        previewTask?.cancel()
        previewing = true
        applyAudioState()
        let script: [(Int, UInt16, KeyPhase)] = [
            (0, 17, .down), (75, 17, .up), (45, 34, .down), (70, 34, .up), (55, 40, .down), (80, 40, .up),
            (85, 49, .down), (95, 49, .up), (110, 4, .down), (70, 4, .up), (45, 31, .down), (75, 31, .up),
            (60, 14, .down), (80, 14, .up), (120, 36, .down), (115, 36, .up),
        ]
        previewTask = Task { [weak self] in
            for (delay, code, phase) in script {
                try? await Task.sleep(for: .milliseconds(delay))
                if Task.isCancelled { return }
                self?.engine.play(keyCode: code, phase: phase)
            }
            try? await Task.sleep(for: .milliseconds(700))
            if Task.isCancelled { return }
            self?.endPreview()
        }
    }

    /// Plays one key (used by the test pad in Settings).
    func playTestKey(_ code: UInt16) {
        previewTask?.cancel()
        previewing = true
        applyAudioState()
        engine.play(keyCode: code, phase: .down)
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            if Task.isCancelled { return }
            self?.engine.play(keyCode: code, phase: .up)
            try? await Task.sleep(for: .milliseconds(900))
            if Task.isCancelled { return }
            self?.endPreview()
        }
    }

    private func endPreview() {
        previewing = false
        applyAudioState()
    }

    // MARK: Packs

    /// One time: anyone still on the old default (synthesized Cream) moves to the recorded Cream,
    /// now that the recorded styles lead the list. Later choices are never touched.
    private func migrateToRecordedDefault() {
        let key = "tik.migration.recordedDefault"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if settings.packID == "com.tik.pack.cream", packs.contains(where: { $0.id == TikSettings.defaultPackID }) {
            update { $0.packID = TikSettings.defaultPackID }
        }
    }

    func reloadPacks() {
        packs = PackLibrary.discover()
    }

    func selectPack(_ id: String, preview: Bool = true) {
        if settings.packID == id && activePackID == id {
            if preview { playPreview() }
            return
        }
        previewAfterLoad = preview
        if settings.packID == id {
            loadActivePack()
        } else {
            update { $0.packID = id }
        }
    }

    private func loadActivePack() {
        guard let info = packs.first(where: { $0.id == settings.packID })
                ?? packs.first(where: { $0.id == TikSettings.defaultPackID })
                ?? packs.first
        else {
            notice = "No sound packs were found in the app bundle."
            return
        }
        isLoadingPack = true
        let requestedID = settings.packID
        let source = info.source
        Task.detached(priority: .userInitiated) {
            let result = Result { try PackLibrary.load(source) }
            await MainActor.run {
                AppModel.shared.finishLoading(info: info, requestedID: requestedID, result: result)
            }
        }
    }

    private func finishLoading(info: PackInfo, requestedID: String, result: Result<SoundBank, Error>) {
        guard requestedID == settings.packID else { return }   // a newer selection is loading
        isLoadingPack = false
        switch result {
        case .success(let bank):
            engine.setBank(bank)
            activePackID = bank.id
            activePackName = bank.name
            if info.id != requestedID {
                notice = "The selected pack is missing, so Tik is using \(bank.name)."
            }
            if previewAfterLoad {
                previewAfterLoad = false
                playPreview()
            }
        case .failure(let error):
            notice = "\(info.name): \(error.localizedDescription)"
            if requestedID != TikSettings.defaultPackID {
                update { $0.packID = TikSettings.defaultPackID }
            }
        }
    }

    func importPack() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a sound-pack folder that contains manifest.json"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let info = try PackLibrary.importFolder(url)
            reloadPacks()
            notice = "Imported “\(info.name)”."
            selectPack(info.id)
        } catch {
            notice = "Import failed: \(error.localizedDescription)"
        }
    }

    func exportActivePack() {
        guard let bank = engine.currentBank else { return }
        let summary = packs.first(where: { $0.id == bank.id })?.summary ?? ""
        do {
            let folder = try PackLibrary.exportEditable(bank, summary: summary)
            reloadPacks()
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            notice = "Saved an editable copy of \(bank.name). Replace its WAVs, then press Reload."
        } catch {
            notice = "Export failed: \(error.localizedDescription)"
        }
    }

    func deletePack(_ info: PackInfo) {
        guard case .folder(let url) = info.source else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            do { try FileManager.default.removeItem(at: url) } catch {
                notice = "Couldn't remove \(info.name): \(error.localizedDescription)"
                return
            }
        }
        reloadPacks()
        if settings.packID == info.id { update { $0.packID = TikSettings.defaultPackID } }
    }

    func revealPacksFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([PackLibrary.packsDirectory])
    }

    // MARK: Login item

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            notice = "Couldn't change Launch at Login: \(error.localizedDescription)"
        }
        refreshLaunchAtLogin()
    }

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Sleep / wake

    private func installSystemObservers() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.audio.suspend()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scheduleWakeRecovery()
            }
        })
    }

    private func scheduleWakeRecovery() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.checkPermission()
            self.tap.reenableIfNeeded()
            self.audio.resumeIfNeeded()
            self.syncAudioState()
        }
    }

    // MARK: Diagnostics

    func diagnostics() -> DiagnosticsSnapshot {
        let bank = engine.currentBank
        return DiagnosticsSnapshot(
            output: audio.currentInfo(),
            mixer: engine.mixer.stats(),
            counters: engine.counterSnapshot(),
            permissionGranted: InputPermission.isGranted,
            tapRunning: tap.isRunning,
            tapEnabled: tap.isEnabled,
            tapRecoveries: tap.timeoutRecoveries,
            secureInput: IsSecureEventInputEnabled(),
            packName: bank?.name ?? "None",
            packClips: bank?.clipCount ?? 0,
            packSeconds: bank?.totalSeconds ?? 0,
            packMemoryKB: (bank?.approximateMemoryBytes ?? 0) / 1024
        )
    }

    func diagnosticsReport() -> String {
        let d = diagnostics()
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        #if arch(arm64)
        let arch = "Apple Silicon (arm64)"
        #else
        let arch = "Intel (x86_64)"
        #endif
        func ms(_ v: Double) -> String { String(format: "%.2f ms", v) }
        return """
        Tik \(version) (\(build))
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Hardware: \(arch)
        Input permission: \(d.permissionGranted ? "granted" : "not granted")
        Event tap: \(d.tapRunning ? (d.tapEnabled ? "running" : "disabled by macOS") : "not running") · recoveries \(d.tapRecoveries)
        Secure input active: \(d.secureInput ? "yes" : "no")
        Enabled: \(settings.enabled ? "yes" : "no")
        Audio engine: \(d.output.running ? "running" : "stopped")\(d.output.lastError.map { " · \($0)" } ?? "")
        Output device: \(d.output.deviceName)\(d.output.isBluetooth ? " (Bluetooth)" : "")
        Sample rate: \(Int(d.output.sampleRate)) Hz · IO buffer \(d.output.bufferFrames) frames
        Device latency: \(ms(d.output.presentationLatency * 1000)) · est. output path \(ms(d.output.estimatedOutputMs))
        Tik queue latency: avg \(ms(d.mixer.averageMs)) · max \(ms(d.mixer.maxMs)) over \(d.mixer.commands) sounds
        Active voices: \(d.mixer.activeVoices) / \(VoiceMixer.maxVoices) · dropped \(d.mixer.dropped)
        Engine starts: \(d.output.rebuilds)
        Pack: \(d.packName) · \(d.packClips) clips · \(String(format: "%.1f", d.packSeconds)) s · \(d.packMemoryKB) KB
        Events seen: \(d.counters.events) · sounds: \(d.counters.sounds) · ignored synthetic: \(d.counters.ignoredSynthetic)
        (No key codes, characters or typing history are included.)
        """
    }
}
