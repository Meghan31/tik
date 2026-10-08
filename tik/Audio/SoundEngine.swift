//
//  SoundEngine.swift
//  tik
//
//  Decides what each key event should sound like and hands it to the mixer.
//  Runs on the event-tap thread. The only shared state (settings, bank, key state,
//  shuffle bags, RNG) sits behind one uncontended lock that's held for microseconds.
//

import Foundation
import Darwin

nonisolated struct EngineCounters: Sendable {
    var events: UInt64 = 0
    var sounds: UInt64 = 0
    var ignoredSynthetic: UInt64 = 0
}

nonisolated final class SoundEngine: @unchecked Sendable {
    let mixer = VoiceMixer()

    /// Called on the event-tap thread when the on/off double tap is recognized. Set once before the tap starts.
    var onToggleHotkey: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var settings = TikSettings()
    private var bank: SoundBank?
    private var downBags: [ShuffleBag] = []
    private var upBags: [ShuffleBag] = []
    private var keyState = KeyState()
    private var rng = SplitMix64(seed: mach_absolute_time() | 1)
    private var audible = false
    private var counters = EngineCounters()
    private var doubleTap = DoubleTapDetector()
    private let ticksPerSecond: Double

    init() {
        KeyMap.warmUp()
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        ticksPerSecond = tb.numer == 0 ? 1e9 : 1e9 * Double(tb.denom) / Double(tb.numer)
    }

    // MARK: Configuration (main thread)

    func apply(_ newSettings: TikSettings) {
        lock.lock()
        settings = newSettings
        lock.unlock()
    }

    /// Swaps the active pack. The old bank is kept alive a few seconds so voices
    /// still playing from it never read freed memory.
    func setBank(_ newBank: SoundBank?) {
        lock.lock()
        let old = bank
        bank = newBank
        downBags = newBank?.groups.map { ShuffleBag(count: $0.down.count) } ?? []
        upBags = newBank?.groups.map { ShuffleBag(count: $0.up.count) } ?? []
        lock.unlock()
        if let old {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                withExtendedLifetime(old) {}
            }
        }
    }

    var currentBank: SoundBank? {
        lock.lock()
        defer { lock.unlock() }
        return bank
    }

    /// Whether audio output is running. While false, nothing is queued.
    func setAudible(_ on: Bool) {
        lock.lock()
        audible = on
        if !on { keyState.reset() }
        lock.unlock()
    }

    func counterSnapshot() -> EngineCounters {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    // MARK: Event path (event-tap thread)

    func handle(_ event: TikKeyEvent, synthetic: Bool) {
        lock.lock()
        counters.events &+= 1

        // On/off gesture. Runs even while Tik is off, so it can turn Tik back on.
        if let target = settings.toggleShortcut.doubleTapKeyCode,
           doubleTap.feed(event, target: target, now: mach_absolute_time(), ticksPerSecond: ticksPerSecond) {
            lock.unlock()
            onToggleHotkey?()
            return
        }

        guard settings.enabled, audible else {
            lock.unlock()
            return
        }
        if synthetic && settings.ignoreSyntheticEvents {
            counters.ignoredSynthetic &+= 1
            lock.unlock()
            return
        }
        guard let phase = keyState.process(event, repeatMode: settings.repeatMode) else {
            lock.unlock()
            return
        }
        if phase == .up && !settings.releaseSounds
            || event.kind == .flagsChanged && !settings.modifierSounds
            || (event.kind == .mouseDown || event.kind == .mouseUp) && !settings.mouseSounds {
            lock.unlock()
            return
        }
        let command = makeCommandLocked(code: event.keyCode, phase: phase)
        if command != nil { counters.sounds &+= 1 }
        lock.unlock()

        if let command { mixer.enqueue(command) }
    }

    /// Plays a key sound directly (previews, test buttons). Ignores enabled state and key state.
    func play(keyCode: UInt16, phase: KeyPhase) {
        lock.lock()
        let command = audible ? makeCommandLocked(code: keyCode, phase: phase) : nil
        lock.unlock()
        if let command { mixer.enqueue(command) }
    }

    /// Picks a variant and computes gain, pitch and pan. Caller holds the lock.
    private func makeCommandLocked(code: UInt16, phase: KeyPhase) -> PlayCommand? {
        guard let bank, settings.volume > 0.001 else { return nil }
        let g = bank.group(for: code)
        guard g >= 0, g < bank.groups.count else { return nil }

        let clip: Clip
        switch phase {
        case .down:
            let clips = bank.groups[g].down
            guard !clips.isEmpty else { return nil }
            clip = clips[min(downBags[g].next(using: &rng), clips.count - 1)]
        case .up:
            let clips = bank.groups[g].up
            guard !clips.isEmpty else { return nil }
            clip = clips[min(upBags[g].next(using: &rng), clips.count - 1)]
        }

        let s = settings
        var gain = s.volume * s.volume * bank.gain
        gain *= powf(10, rng.bipolar() * s.gainVariation / 20)
        if phase == .up { gain *= s.releaseVolume }

        let cents = KeyMap.characterCents(for: code) * s.keyCharacter + rng.bipolar() * s.pitchVariation
        let rate = exp2f(cents / 1200)

        let x = max(-1, min(1, KeyMap.position(for: code).x * s.spatialWidth))
        let theta = (x + 1) * Float.pi / 4
        let norm = Float(2).squareRoot()        // centre = unity gain on both channels
        return PlayCommand(samples: clip.samples, count: Int32(clamping: clip.count), rate: rate,
                           gainL: gain * cosf(theta) * norm, gainR: gain * sinf(theta) * norm,
                           stamp: mach_absolute_time())
    }
}
