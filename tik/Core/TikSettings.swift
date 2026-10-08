//
//  TikSettings.swift
//  tik
//

import Foundation

nonisolated enum LatencyMode: String, Codable, CaseIterable, Sendable {
    case lowest
    case balanced
    case efficient

    /// Output IO buffer size requested from Core Audio.
    var bufferFrames: UInt32 {
        switch self {
        case .lowest: return 128
        case .balanced: return 256
        case .efficient: return 512
        }
    }

    var label: String {
        switch self {
        case .lowest: return "Lowest latency"
        case .balanced: return "Balanced"
        case .efficient: return "Battery saver"
        }
    }
}

nonisolated struct TikSettings: Codable, Equatable, Sendable {
    static let defaultPackID = "com.tik.pack.rec.cream"

    var enabled = true
    var packID = TikSettings.defaultPackID
    var volume: Float = 0.7               // 0...1, perceptual (squared) curve
    var pitchVariation: Float = 15        // ± cents per keystroke
    var gainVariation: Float = 1.0        // ± dB per keystroke
    var releaseVolume: Float = 1.0        // 0...1 multiplier for key-up sounds
    var spatialWidth: Float = 0.35        // 0...1 stereo spread by key position
    var keyCharacter: Float = 0.5         // 0...1 consistent per-key pitch personality
    var releaseSounds = true
    var modifierSounds = true
    var mouseSounds = false
    var repeatMode: RepeatMode = .firstOnly
    var ignoreSyntheticEvents = false
    var latencyMode: LatencyMode = .balanced
    var toggleShortcut: ToggleShortcut = .doubleTapRightOption
    var comboKeyCode: Int = -1            // -1 = nothing recorded yet
    var comboModifiers: UInt32 = 0        // Carbon modifier flags (cmdKey, optionKey, …)
    var comboLabel = ""
    var hasCompletedOnboarding = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TikSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        enabled = value(.enabled, d.enabled)
        packID = value(.packID, d.packID)
        volume = value(.volume, d.volume)
        pitchVariation = value(.pitchVariation, d.pitchVariation)
        gainVariation = value(.gainVariation, d.gainVariation)
        releaseVolume = value(.releaseVolume, d.releaseVolume)
        spatialWidth = value(.spatialWidth, d.spatialWidth)
        keyCharacter = value(.keyCharacter, d.keyCharacter)
        releaseSounds = value(.releaseSounds, d.releaseSounds)
        modifierSounds = value(.modifierSounds, d.modifierSounds)
        mouseSounds = value(.mouseSounds, d.mouseSounds)
        repeatMode = value(.repeatMode, d.repeatMode)
        ignoreSyntheticEvents = value(.ignoreSyntheticEvents, d.ignoreSyntheticEvents)
        latencyMode = value(.latencyMode, d.latencyMode)
        toggleShortcut = value(.toggleShortcut, d.toggleShortcut)
        comboKeyCode = value(.comboKeyCode, d.comboKeyCode)
        comboModifiers = value(.comboModifiers, d.comboModifiers)
        comboLabel = value(.comboLabel, d.comboLabel)
        hasCompletedOnboarding = value(.hasCompletedOnboarding, d.hasCompletedOnboarding)
        sanitize()
    }

    /// Clamp everything into range so corrupt or hand-edited preferences can't break playback.
    mutating func sanitize() {
        func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
            v.isFinite ? min(max(v, lo), hi) : lo
        }
        volume = clamp(volume, 0, 1)
        pitchVariation = clamp(pitchVariation, 0, 60)
        gainVariation = clamp(gainVariation, 0, 4)
        releaseVolume = clamp(releaseVolume, 0, 1)
        spatialWidth = clamp(spatialWidth, 0, 1)
        keyCharacter = clamp(keyCharacter, 0, 1)
        if packID.isEmpty { packID = TikSettings.defaultPackID }
    }

    /// Resets only the sound-shaping values, keeping behavior and pack choice.
    mutating func resetTuning() {
        let d = TikSettings()
        pitchVariation = d.pitchVariation
        gainVariation = d.gainVariation
        releaseVolume = d.releaseVolume
        spatialWidth = d.spatialWidth
        keyCharacter = d.keyCharacter
    }
}

nonisolated enum SettingsStore {
    private static let key = "tik.settings.v1"

    static func load() -> TikSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(TikSettings.self, from: data)
        else { return TikSettings() }
        return s
    }

    static func save(_ settings: TikSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
