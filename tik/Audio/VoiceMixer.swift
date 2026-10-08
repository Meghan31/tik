//
//  VoiceMixer.swift
//  tik
//
//  The real-time heart of Tik: a small polyphonic sampler.
//
//  Producers (the event-tap thread, previews) push PlayCommands into a lock-free ring.
//  The audio render thread drains the ring at the start of every IO cycle, starts a voice
//  per command and mixes all active voices with per-voice pitch (resampling), gain and pan.
//
//  The render path takes no locks, allocates nothing and never touches the file system.
//

import Foundation
import Darwin
import Synchronization

nonisolated struct PlayCommand: @unchecked Sendable {
    var samples: UnsafePointer<Float>?
    var count: Int32
    var rate: Float         // playback rate from pitch variation (1 = original pitch)
    var gainL: Float
    var gainR: Float
    var stamp: UInt64       // mach_absolute_time() at enqueue, for latency diagnostics
}

nonisolated struct Voice {
    var samples: UnsafePointer<Float>?
    var count: Int
    var position: Double
    var step: Double
    var gainL: Float
    var gainR: Float
    var serial: UInt64

    static let idle = Voice(samples: nil, count: 0, position: 0, step: 1, gainL: 0, gainR: 0, serial: 0)
}

nonisolated struct MixerStats: Sendable {
    var commands: UInt64
    var averageMs: Double
    var maxMs: Double
    var activeVoices: Int
    var dropped: UInt64
}

nonisolated final class VoiceMixer: @unchecked Sendable {
    static let maxVoices = 64
    private static let ringCapacity = 256          // power of two
    private static let ringMask = ringCapacity - 1

    private let ring: UnsafeMutablePointer<PlayCommand>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)
    private let producerLock = NSLock()

    private let voices: UnsafeMutablePointer<Voice>
    private var serial: UInt64 = 0                  // render thread only
    private let clearRequested = Atomic<Bool>(false)

    // Diagnostics, written by the render thread.
    private let statCount = Atomic<UInt64>(0)
    private let statSumTicks = Atomic<UInt64>(0)
    private let statMaxTicks = Atomic<UInt64>(0)
    private let statActive = Atomic<Int>(0)
    private let statDropped = Atomic<UInt64>(0)
    private let tickToNanos: Double

    init() {
        ring = UnsafeMutablePointer<PlayCommand>.allocate(capacity: VoiceMixer.ringCapacity)
        ring.initialize(repeating: PlayCommand(samples: nil, count: 0, rate: 1, gainL: 0, gainR: 0, stamp: 0),
                        count: VoiceMixer.ringCapacity)
        voices = UnsafeMutablePointer<Voice>.allocate(capacity: VoiceMixer.maxVoices)
        voices.initialize(repeating: Voice.idle, count: VoiceMixer.maxVoices)
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        tickToNanos = tb.denom == 0 ? 1 : Double(tb.numer) / Double(tb.denom)
    }

    deinit {
        ring.deinitialize(count: VoiceMixer.ringCapacity)
        ring.deallocate()
        voices.deinitialize(count: VoiceMixer.maxVoices)
        voices.deallocate()
    }

    // MARK: Producer side (any thread except the render thread)

    /// Queues a sound. Returns false only if 256 sounds are already waiting (never in practice).
    @discardableResult
    func enqueue(_ command: PlayCommand) -> Bool {
        producerLock.lock()
        defer { producerLock.unlock() }
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        if w &- r >= VoiceMixer.ringCapacity {
            statDropped.wrappingAdd(1, ordering: .relaxed)
            return false
        }
        ring[w & VoiceMixer.ringMask] = command
        writeIndex.store(w &+ 1, ordering: .releasing)
        return true
    }

    /// Drops queued commands and silences all voices. Only call while no render is running
    /// (audio engine stopped), e.g. right before starting output, so stale sounds can't burst out.
    func resetWhileStopped() {
        producerLock.lock()
        readIndex.store(writeIndex.load(ordering: .acquiring), ordering: .releasing)
        producerLock.unlock()
        for i in 0..<VoiceMixer.maxVoices { voices[i] = Voice.idle }
        statActive.store(0, ordering: .relaxed)
    }

    /// Asks the render thread to silence every voice on its next cycle (safe while running).
    func requestClear() {
        clearRequested.store(true, ordering: .releasing)
    }

    static func now() -> UInt64 {
        mach_absolute_time()
    }

    // MARK: Render side (audio thread)

    /// Fills `frames` samples of stereo output. Returns true if the output is pure silence.
    /// `sampleRateRatio` is clipRate / outputRate.
    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
                sampleRateRatio: Double) -> Bool {
        if clearRequested.load(ordering: .acquiring) {
            clearRequested.store(false, ordering: .relaxed)
            for i in 0..<VoiceMixer.maxVoices { voices[i].samples = nil }
        }

        // 1. Start voices for everything queued since the last cycle.
        let w = writeIndex.load(ordering: .acquiring)
        var r = readIndex.load(ordering: .relaxed)
        if r != w {
            let now = mach_absolute_time()
            while r != w {
                let command = ring[r & VoiceMixer.ringMask]
                startVoice(command, sampleRateRatio: sampleRateRatio)
                if command.stamp != 0, now > command.stamp {
                    let d = now - command.stamp
                    statCount.wrappingAdd(1, ordering: .relaxed)
                    statSumTicks.wrappingAdd(d, ordering: .relaxed)
                    if d > statMaxTicks.load(ordering: .relaxed) { statMaxTicks.store(d, ordering: .relaxed) }
                }
                r &+= 1
            }
            readIndex.store(r, ordering: .releasing)
        }

        // 2. Mix.
        left.update(repeating: 0, count: frames)
        right.update(repeating: 0, count: frames)
        var active = 0
        for vi in 0..<VoiceMixer.maxVoices {
            var v = voices[vi]
            guard let s = v.samples else { continue }
            let last = v.count - 1
            var pos = v.position
            let step = v.step
            let gl = v.gainL
            let gr = v.gainR
            var i = 0
            while i < frames {
                let idx = Int(pos)
                if idx >= last {
                    v.samples = nil
                    break
                }
                let frac = Float(pos - Double(idx))
                let a = s[idx]
                let x = a + (s[idx + 1] - a) * frac
                left[i] += x * gl
                right[i] += x * gr
                pos += step
                i += 1
            }
            v.position = pos
            voices[vi] = v
            if v.samples != nil { active += 1 }
        }
        statActive.store(active, ordering: .relaxed)

        if active == 0 && r == w {
            // Everything finished inside this buffer still produced samples above; only report
            // silence when nothing at all was mixed.
            var silent = true
            for i in 0..<frames where left[i] != 0 || right[i] != 0 {
                silent = false
                break
            }
            if silent { return true }
        }

        // 3. Gentle soft clip so heavy chords never hard-clip.
        VoiceMixer.softClip(left, frames)
        VoiceMixer.softClip(right, frames)
        return false
    }

    private func startVoice(_ c: PlayCommand, sampleRateRatio: Double) {
        guard let s = c.samples, c.count > 1 else { return }
        var target = -1
        var oldestSerial = UInt64.max
        var oldestIndex = 0
        for i in 0..<VoiceMixer.maxVoices {
            let v = voices[i]
            if v.samples == nil {
                target = i
                break
            }
            if v.serial < oldestSerial {
                oldestSerial = v.serial
                oldestIndex = i
            }
        }
        if target < 0 { target = oldestIndex }    // steal the oldest voice
        serial &+= 1
        voices[target] = Voice(samples: s, count: Int(c.count), position: 0,
                               step: Double(c.rate) * sampleRateRatio,
                               gainL: c.gainL, gainR: c.gainR, serial: serial)
    }

    @inline(__always)
    private static func softClip(_ p: UnsafeMutablePointer<Float>, _ n: Int) {
        for i in 0..<n {
            let x = p[i]
            let a = abs(x)
            if a > 0.8 {
                let y = 0.8 + 0.2 * tanhf((a - 0.8) / 0.2)
                p[i] = x < 0 ? -y : y
            }
        }
    }

    // MARK: Diagnostics (any thread)

    func stats() -> MixerStats {
        let n = statCount.load(ordering: .relaxed)
        let sum = statSumTicks.load(ordering: .relaxed)
        let mx = statMaxTicks.load(ordering: .relaxed)
        let avg = n > 0 ? Double(sum) / Double(n) * tickToNanos / 1_000_000 : 0
        return MixerStats(commands: n, averageMs: avg, maxMs: Double(mx) * tickToNanos / 1_000_000,
                          activeVoices: statActive.load(ordering: .relaxed),
                          dropped: statDropped.load(ordering: .relaxed))
    }

    func resetStats() {
        statCount.store(0, ordering: .relaxed)
        statSumTicks.store(0, ordering: .relaxed)
        statMaxTicks.store(0, ordering: .relaxed)
        statDropped.store(0, ordering: .relaxed)
    }
}
