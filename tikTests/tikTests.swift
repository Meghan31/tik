//
//  tikTests.swift
//  tikTests
//
//  Unit tests for the parts of Tik that don't need a keyboard or speakers.
//  Run with ⌘U.
//

import Testing
import Foundation
@testable import tik

struct KeyStateTests {

    @Test func firstPressOnlyIgnoresRepeats() {
        var s = KeyState()
        #expect(s.process(TikKeyEvent(kind: .keyDown, keyCode: 0), repeatMode: .firstOnly) == .down)
        #expect(s.process(TikKeyEvent(kind: .keyDown, keyCode: 0, isRepeat: true), repeatMode: .firstOnly) == nil)
        #expect(s.process(TikKeyEvent(kind: .keyUp, keyCode: 0), repeatMode: .firstOnly) == .up)
    }

    @Test func everyRepeatSoundsRepeats() {
        var s = KeyState()
        _ = s.process(TikKeyEvent(kind: .keyDown, keyCode: 0), repeatMode: .everyRepeat)
        #expect(s.process(TikKeyEvent(kind: .keyDown, keyCode: 0, isRepeat: true), repeatMode: .everyRepeat) == .down)
    }

    @Test func leftAndRightShiftAreIndependent() {
        var s = KeyState()
        let lDown = ModifierBits.shift | ModifierBits.leftShift
        let bothDown = lDown | ModifierBits.rightShift
        #expect(s.process(TikKeyEvent(kind: .flagsChanged, keyCode: 56, flags: lDown), repeatMode: .firstOnly) == .down)
        #expect(s.process(TikKeyEvent(kind: .flagsChanged, keyCode: 60, flags: bothDown), repeatMode: .firstOnly) == .down)
        // release left while right is still held
        let rOnly = ModifierBits.shift | ModifierBits.rightShift
        #expect(s.process(TikKeyEvent(kind: .flagsChanged, keyCode: 56, flags: rOnly), repeatMode: .firstOnly) == .up)
        #expect(s.process(TikKeyEvent(kind: .flagsChanged, keyCode: 60, flags: 0), repeatMode: .firstOnly) == .up)
    }

    @Test func functionKeyTogglesWithoutDeviceBits() {
        var s = KeyState()
        #expect(s.process(TikKeyEvent(kind: .flagsChanged, keyCode: 63, flags: ModifierBits.function),
                          repeatMode: .firstOnly) == .down)
        #expect(s.process(TikKeyEvent(kind: .flagsChanged, keyCode: 63, flags: 0), repeatMode: .firstOnly) == .up)
    }

    @Test func releaseWithoutPressIsSilent() {
        var s = KeyState()
        #expect(s.process(TikKeyEvent(kind: .flagsChanged, keyCode: 55, flags: 0), repeatMode: .firstOnly) == nil)
    }

    @Test func capsLockSoundsOnce() {
        var s = KeyState()
        #expect(s.process(TikKeyEvent(kind: .flagsChanged, keyCode: 57, flags: ModifierBits.capsLock),
                          repeatMode: .firstOnly) == .down)
    }

}

struct ToggleShortcutTests {
    // 1 tick = 1 ms in these tests
    private let tps = 1000.0
    private let rightOptionDown = TikKeyEvent(kind: .flagsChanged, keyCode: 61,
                                              flags: ModifierBits.option | ModifierBits.rightOption)
    private let rightOptionUp = TikKeyEvent(kind: .flagsChanged, keyCode: 61, flags: 0)

    @Test func cleanDoubleTapFires() {
        var d = DoubleTapDetector()
        #expect(!d.feed(rightOptionDown, target: 61, now: 1_000, ticksPerSecond: tps))
        #expect(!d.feed(rightOptionUp, target: 61, now: 1_080, ticksPerSecond: tps))
        #expect(!d.feed(rightOptionDown, target: 61, now: 1_200, ticksPerSecond: tps))
        #expect(d.feed(rightOptionUp, target: 61, now: 1_260, ticksPerSecond: tps))
    }

    @Test func slowSecondTapDoesNotFire() {
        var d = DoubleTapDetector()
        _ = d.feed(rightOptionDown, target: 61, now: 1_000, ticksPerSecond: tps)
        _ = d.feed(rightOptionUp, target: 61, now: 1_080, ticksPerSecond: tps)
        _ = d.feed(rightOptionDown, target: 61, now: 1_700, ticksPerSecond: tps)
        #expect(!d.feed(rightOptionUp, target: 61, now: 1_760, ticksPerSecond: tps))
    }

    @Test func holdingIsNotATap() {
        var d = DoubleTapDetector()
        _ = d.feed(rightOptionDown, target: 61, now: 1_000, ticksPerSecond: tps)
        _ = d.feed(rightOptionUp, target: 61, now: 1_600, ticksPerSecond: tps)
        _ = d.feed(rightOptionDown, target: 61, now: 1_700, ticksPerSecond: tps)
        #expect(!d.feed(rightOptionUp, target: 61, now: 1_760, ticksPerSecond: tps))
    }

    @Test func typingBetweenTapsCancels() {
        var d = DoubleTapDetector()
        _ = d.feed(rightOptionDown, target: 61, now: 1_000, ticksPerSecond: tps)
        _ = d.feed(rightOptionUp, target: 61, now: 1_080, ticksPerSecond: tps)
        _ = d.feed(TikKeyEvent(kind: .keyDown, keyCode: 0), target: 61, now: 1_100, ticksPerSecond: tps)
        _ = d.feed(rightOptionDown, target: 61, now: 1_200, ticksPerSecond: tps)
        #expect(!d.feed(rightOptionUp, target: 61, now: 1_260, ticksPerSecond: tps))
    }

    @Test func optionPlusLetterIsNotATap() {
        // ⌥+E (accent dead key) must never count as a tap.
        var d = DoubleTapDetector()
        _ = d.feed(rightOptionDown, target: 61, now: 1_000, ticksPerSecond: tps)
        _ = d.feed(TikKeyEvent(kind: .keyDown, keyCode: 14, flags: ModifierBits.option), target: 61, now: 1_030, ticksPerSecond: tps)
        _ = d.feed(rightOptionUp, target: 61, now: 1_080, ticksPerSecond: tps)
        _ = d.feed(rightOptionDown, target: 61, now: 1_200, ticksPerSecond: tps)
        #expect(!d.feed(rightOptionUp, target: 61, now: 1_260, ticksPerSecond: tps))
    }

    @Test func otherModifierHeldCancels() {
        var d = DoubleTapDetector()
        let withCommand = TikKeyEvent(kind: .flagsChanged, keyCode: 61,
                                      flags: ModifierBits.option | ModifierBits.rightOption | ModifierBits.command)
        _ = d.feed(withCommand, target: 61, now: 1_000, ticksPerSecond: tps)
        _ = d.feed(rightOptionUp, target: 61, now: 1_080, ticksPerSecond: tps)
        _ = d.feed(withCommand, target: 61, now: 1_200, ticksPerSecond: tps)
        #expect(!d.feed(rightOptionUp, target: 61, now: 1_260, ticksPerSecond: tps))
    }

    @Test func leftOptionDoesNotCount() {
        var d = DoubleTapDetector()
        let leftDown = TikKeyEvent(kind: .flagsChanged, keyCode: 58, flags: ModifierBits.option | ModifierBits.leftOption)
        let leftUp = TikKeyEvent(kind: .flagsChanged, keyCode: 58, flags: 0)
        _ = d.feed(leftDown, target: 61, now: 1_000, ticksPerSecond: tps)
        _ = d.feed(leftUp, target: 61, now: 1_080, ticksPerSecond: tps)
        _ = d.feed(leftDown, target: 61, now: 1_200, ticksPerSecond: tps)
        #expect(!d.feed(leftUp, target: 61, now: 1_260, ticksPerSecond: tps))
    }

    @Test func comboRules() {
        let cmd = ShortcutRules.command, opt = ShortcutRules.option
        let ctrl = ShortcutRules.control, shift = ShortcutRules.shift
        #expect(ShortcutRules.problem(keyCode: 17, modifiers: cmd) != nil)            // ⌘T belongs to apps
        #expect(ShortcutRules.problem(keyCode: 17, modifiers: opt | shift) != nil)    // could type a character
        #expect(ShortcutRules.problem(keyCode: 17, modifiers: ctrl | opt) == nil)     // ⌃⌥T is fine
        #expect(ShortcutRules.problem(keyCode: 96, modifiers: ctrl) == nil)           // ⌃F5 is fine
        #expect(ShortcutRules.problem(keyCode: 53, modifiers: ctrl | opt) != nil)     // Escape is reserved
        #expect(ShortcutRules.label(keyCode: 17, modifiers: ctrl | opt | cmd, characters: "t") == "⌃⌥⌘T")
        #expect(ShortcutRules.label(keyCode: 49, modifiers: ctrl | opt, characters: " ") == "⌃⌥Space")
    }
}

struct SlicerTests {
    private func burst(_ x: inout [Float], at start: Int, length: Int, amp: Float, tau: Float, rng: inout SplitMix64) {
        for i in 0..<length where start + i < x.count {
            x[start + i] += amp * expf(-Float(i) / tau) * rng.bipolar()
        }
    }

    private func floorNoise(_ seconds: Double, rng: inout SplitMix64) -> [Float] {
        (0..<Int(seconds * 48_000)).map { _ in rng.bipolar() * 1e-4 }
    }

    @Test func findsPressesAndReleases() {
        var rng = SplitMix64(seed: 1)
        var x = floorNoise(4, rng: &rng)
        for k in 0..<6 {
            let s = Int((0.3 + Double(k) * 0.5) * 48_000)
            burst(&x, at: s, length: 2_400, amp: 0.6, tau: 240, rng: &rng)
            burst(&x, at: s + 4_800, length: 1_200, amp: 0.2, tau: 120, rng: &rng)
        }
        let result = SoundSlicer.slice(x)
        #expect(result.downs.count == 6)
        #expect(result.ups.count == 6)
    }

    @Test func singleHitStartsAtTheTransient() {
        var rng = SplitMix64(seed: 2)
        var x = floorNoise(1, rng: &rng)
        burst(&x, at: 12_000, length: 2_400, amp: 0.6, tau: 240, rng: &rng)
        let hits = SoundSlicer.findHits(x)
        #expect(hits.count == 1)
        #expect(abs(hits[0].start - 12_000) < 120)                      // within 2.5 ms
        #expect(SoundSlicer.slice(x).ups.isEmpty)
    }

    @Test func hitsWithoutReleasesStayPresses() {
        var rng = SplitMix64(seed: 3)
        var x = floorNoise(3, rng: &rng)
        for k in 0..<5 {
            burst(&x, at: Int((0.2 + Double(k) * 0.4) * 48_000), length: 2_400, amp: 0.5, tau: 240, rng: &rng)
        }
        let result = SoundSlicer.slice(x)
        #expect(result.downs.count == 5)
        #expect(result.ups.isEmpty)
    }

    @Test func oneRowFillsLettersAndCreatesReleases() throws {
        var rng = SplitMix64(seed: 4)
        var clip = [Float](repeating: 0, count: 4_800)
        burst(&clip, at: 0, length: 4_800, amp: 0.3, tau: 400, rng: &rng)
        var space = SlotAudio()
        space.downs = [clip, clip.map { $0 * 0.5 }]
        let pack = try #require(PackAssembler.assemble(name: "Test", slots: [.space: space],
                                                       generateReleases: true, evenOut: true))
        let alpha = try #require(pack.groups.first { $0.name == "alpha" })
        #expect(alpha.downs.count == 2)
        #expect(alpha.ups.count == 2)
        let loudest = pack.groups.flatMap { $0.downs + $0.ups }.map(PackAssembler.peak).max() ?? 0
        #expect(loudest <= 0.95)
        let bank = PackAssembler.makeBank(pack)
        #expect(bank.group(for: 0) >= 0)
        #expect(bank.group(for: 49) >= 0)
    }
}

struct SelectionTests {

    @Test func shuffleBagNeverRepeatsBackToBack() {
        var rng = SplitMix64(seed: 42)
        var bag = ShuffleBag(count: 8)
        var last = -1
        var seen = [Int](repeating: 0, count: 8)
        for _ in 0..<8000 {
            let v = bag.next(using: &rng)
            #expect(v != last)
            #expect((0..<8).contains(v))
            seen[v] += 1
            last = v
        }
        #expect(seen.allSatisfy { $0 == 1000 })
    }

    @Test func bipolarStaysInRange() {
        var rng = SplitMix64(seed: 7)
        for _ in 0..<10_000 {
            let v = rng.bipolar()
            #expect(v >= -1 && v < 1)
        }
    }
}

struct KeyMapTests {

    @Test func classes() {
        #expect(KeyMap.keyClass(for: 49) == .space)
        #expect(KeyMap.keyClass(for: 36) == .enter)
        #expect(KeyMap.keyClass(for: 51) == .backspace)
        #expect(KeyMap.keyClass(for: 56) == .wide)
        #expect(KeyMap.keyClass(for: 55) == .modifier)
        #expect(KeyMap.keyClass(for: 53) == .function)
        #expect(KeyMap.keyClass(for: 123) == .nav)
        #expect(KeyMap.keyClass(for: 0) == .alpha)
        #expect(KeyMap.keyClass(for: MouseCode.left) == .mouse)
    }

    @Test func positionsAreNormalized() {
        for code in UInt16(0)..<UInt16(128) {
            let p = KeyMap.position(for: code)
            #expect(p.x >= -1 && p.x <= 1)
            #expect(p.y >= -1 && p.y <= 1)
            #expect(abs(KeyMap.characterCents(for: code)) <= 24)
        }
        #expect(KeyMap.position(for: 12).x < KeyMap.position(for: 35).x)   // Q is left of P
    }
}

struct BankTests {

    @Test func fallbacksAndMapping() {
        var b = SoundBankBuilder(id: "t", name: "T")
        b.add(group: "alpha", phase: .down, samples: [0, 0.5, 0])
        b.add(group: "wide", phase: .down, samples: [0, 0.25, 0])
        b.add(group: "custom", phase: .down, samples: [0, 0.1, 0])
        b.mapping = [12: "custom"]
        let bank = b.build()
        let alpha = bank.groups.firstIndex { $0.name == "alpha" }
        let wide = bank.groups.firstIndex { $0.name == "wide" }
        let custom = bank.groups.firstIndex { $0.name == "custom" }
        #expect(bank.group(for: 0) == alpha)
        #expect(bank.group(for: 49) == wide)          // space → wide
        #expect(bank.group(for: 36) == wide)          // enter → wide
        #expect(bank.group(for: 55) == alpha)         // modifier → alpha
        #expect(bank.group(for: 12) == custom)        // manifest override
        #expect(bank.group(for: MouseCode.left) == -1) // no mouse group → silent
        #expect(bank.clipCount == 3)
    }

    @Test func bundledPacksLoad() throws {
        let packs = PackLibrary.discover().filter { $0.isBundled }
        #expect(packs.filter { $0.category == .synthesized }.count == 6)
        #expect(packs.filter { $0.category == .recorded }.count >= 7)
        #expect(packs.first?.category == .recorded)                // recorded styles lead the list
        for pack in packs {
            let bank = try PackLibrary.load(pack.source)
            #expect(bank.group(for: 0) >= 0)
            #expect(bank.group(for: 49) >= 0)
            #expect(bank.group(for: MouseCode.left) >= 0)
            #expect(bank.clipCount >= 40)
        }
    }

    @Test func recordedPacksMapKeysByRow() throws {
        let pack = try #require(PackLibrary.discover().first { $0.id == TikSettings.defaultPackID })
        #expect(pack.color != nil)
        let bank = try PackLibrary.load(pack.source)
        func name(_ code: UInt16) -> String? {
            let g = bank.group(for: code)
            return g >= 0 ? bank.groups[g].name : nil
        }
        #expect(name(12) == "row_top")        // Q
        #expect(name(18) == "row_top")        // 1
        #expect(name(1) == "row_home")        // S
        #expect(name(45) == "row_bottom")     // N
        #expect(name(49) == "space")
        #expect(name(36) == "enter")
        #expect(name(56) == "wide")           // Shift
        #expect(name(51) == "backspace")
        #expect(name(55) == "modifier")       // ⌘
        #expect(name(MouseCode.left) == "mouse")
    }

    @Test func importTrimsLeadingSilence() {
        var input = [Float](repeating: 0, count: 1000)
        input += [Float](repeating: 0.5, count: 500)
        let out = PackLibrary.prepareImported(input)
        #expect(out.count < 600)
        #expect(out.count > 500)
    }

    @Test func resampleLength() {
        let x = [Float](repeating: 0.1, count: 44_100)
        let y = PackLibrary.resample(x, from: 44_100, to: 48_000)
        #expect(abs(y.count - 48_000) <= 2)
    }
}

struct MixerTests {

    @Test func playsClipOnceWithGain() {
        let mixer = VoiceMixer()
        let clip = UnsafeMutablePointer<Float>.allocate(capacity: 32)
        clip.initialize(repeating: 0.5, count: 32)
        defer { clip.deallocate() }

        let left = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        defer { left.deallocate(); right.deallocate() }

        mixer.enqueue(PlayCommand(samples: UnsafePointer(clip), count: 32, rate: 1, gainL: 1, gainR: 0.5, stamp: 0))
        let silent = mixer.render(frames: 64, left: left, right: right, sampleRateRatio: 1)
        #expect(!silent)
        for i in 0..<31 {
            #expect(abs(left[i] - 0.5) < 1e-6)
            #expect(abs(right[i] - 0.25) < 1e-6)
        }
        for i in 31..<64 { #expect(left[i] == 0) }

        let silentAfter = mixer.render(frames: 64, left: left, right: right, sampleRateRatio: 1)
        #expect(silentAfter)
    }

    @Test func overlappingVoicesSum() {
        let mixer = VoiceMixer()
        let clip = UnsafeMutablePointer<Float>.allocate(capacity: 16)
        clip.initialize(repeating: 0.2, count: 16)
        defer { clip.deallocate() }
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 8)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: 8)
        defer { left.deallocate(); right.deallocate() }

        for _ in 0..<3 {
            mixer.enqueue(PlayCommand(samples: UnsafePointer(clip), count: 16, rate: 1, gainL: 1, gainR: 1, stamp: 0))
        }
        _ = mixer.render(frames: 8, left: left, right: right, sampleRateRatio: 1)
        #expect(abs(left[0] - 0.6) < 1e-6)
        #expect(mixer.stats().activeVoices == 3)
    }

    @Test func voiceStealingNeverExceedsPool() {
        let mixer = VoiceMixer()
        let clip = UnsafeMutablePointer<Float>.allocate(capacity: 48_000)
        clip.initialize(repeating: 0.001, count: 48_000)
        defer { clip.deallocate() }
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 128)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: 128)
        defer { left.deallocate(); right.deallocate() }

        for _ in 0..<200 {
            mixer.enqueue(PlayCommand(samples: UnsafePointer(clip), count: 48_000, rate: 1, gainL: 1, gainR: 1, stamp: 0))
        }
        _ = mixer.render(frames: 128, left: left, right: right, sampleRateRatio: 1)
        #expect(mixer.stats().activeVoices == VoiceMixer.maxVoices)
    }
}

struct SettingsTests {

    @Test func corruptValuesAreClamped() throws {
        let json = #"{"volume": 7, "pitchVariation": -3, "packID": "", "repeatMode": "bogus"}"#
        let s = try JSONDecoder().decode(TikSettings.self, from: Data(json.utf8))
        #expect(s.volume == 1)
        #expect(s.pitchVariation == 0)
        #expect(s.packID == TikSettings.defaultPackID)
        #expect(s.repeatMode == .firstOnly)
        #expect(s.releaseSounds == true)
    }

    @Test func roundTrip() throws {
        var s = TikSettings()
        s.volume = 0.42
        s.mouseSounds = true
        s.latencyMode = .lowest
        let back = try JSONDecoder().decode(TikSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}
