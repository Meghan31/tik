//
//  SoundBank.swift
//  tik
//
//  A fully decoded, immutable sound pack held in memory. Nothing here touches disk
//  or decodes audio after construction, so it is safe to read from the real-time path.
//

import Foundation

/// A view into the bank's sample memory. Valid for as long as its SoundBank is alive.
nonisolated struct Clip: @unchecked Sendable {
    let samples: UnsafePointer<Float>
    let count: Int
}

nonisolated struct ClipGroup: @unchecked Sendable {
    let name: String
    let down: [Clip]
    let up: [Clip]
}

nonisolated final class SoundBank: @unchecked Sendable {
    /// All clips are stored at this rate. Loaders resample anything else to it.
    static let standardRate: Double = 48_000

    let id: String
    let name: String
    let gain: Float
    let groups: [ClipGroup]
    /// Group index for every key code (0..<MouseCode.tableSize), or -1 for silence.
    let keyToGroup: [Int16]
    let clipCount: Int
    let totalSeconds: Double

    private let storage: UnsafeMutablePointer<Float>
    private let storageCount: Int

    fileprivate init(id: String, name: String, gain: Float, samples: [Float],
                     groups raw: [(name: String, down: [Range<Int>], up: [Range<Int>])],
                     mapping: [UInt16: String]) {
        let capacity = max(samples.count, 1)
        let memory = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        memory.initialize(repeating: 0, count: capacity)
        samples.withUnsafeBufferPointer { src in
            if let from = src.baseAddress, src.count > 0 {
                memory.update(from: from, count: src.count)
            }
        }
        let base = UnsafePointer(memory)
        var built: [ClipGroup] = []
        var count = 0
        for g in raw {
            let down = g.down.map { Clip(samples: base + $0.lowerBound, count: $0.count) }
            let up = g.up.map { Clip(samples: base + $0.lowerBound, count: $0.count) }
            count += down.count + up.count
            built.append(ClipGroup(name: g.name, down: down, up: up))
        }
        // Resolve every key code to a group once, including fallbacks and manifest overrides.
        var index: [String: Int] = [:]
        for (i, g) in built.enumerated() where !g.down.isEmpty { index[g.name] = i }
        func resolve(_ cls: KeyClass) -> Int {
            var c: KeyClass? = cls
            while let k = c {
                if let i = index[k.rawValue] { return i }
                c = k.fallback
            }
            return -1
        }
        var table = [Int16](repeating: -1, count: MouseCode.tableSize)
        for code in 0..<MouseCode.tableSize {
            let c = UInt16(code)
            if let name = mapping[c], let i = index[name] {
                table[code] = Int16(i)
            } else {
                table[code] = Int16(resolve(KeyMap.keyClass(for: c)))
            }
        }

        self.id = id
        self.name = name
        self.gain = gain
        self.groups = built
        self.clipCount = count
        self.totalSeconds = Double(samples.count) / SoundBank.standardRate
        self.keyToGroup = table
        self.storage = memory
        self.storageCount = capacity
    }

    deinit {
        storage.deinitialize(count: storageCount)
        storage.deallocate()
    }

    func group(for code: UInt16) -> Int {
        let i = Int(code)
        guard i < keyToGroup.count else { return -1 }
        return Int(keyToGroup[i])
    }

    var approximateMemoryBytes: Int { storageCount * MemoryLayout<Float>.size }
}

/// Collects clips while a pack is being loaded, then produces an immutable SoundBank.
nonisolated struct SoundBankBuilder {
    let id: String
    let name: String
    var gain: Float = 1
    var mapping: [UInt16: String] = [:]

    private var samples: [Float] = []
    private var order: [String] = []
    private var down: [String: [Range<Int>]] = [:]
    private var up: [String: [Range<Int>]] = [:]

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    var isEmpty: Bool { samples.isEmpty }
    var totalSamples: Int { samples.count }

    mutating func add(group: String, phase: KeyPhase, samples clip: [Float]) {
        guard clip.count > 1 else { return }
        let start = samples.count
        samples.append(contentsOf: clip)
        let r = start..<samples.count
        if down[group] == nil && up[group] == nil { order.append(group) }
        switch phase {
        case .down: down[group, default: []].append(r)
        case .up: up[group, default: []].append(r)
        }
    }

    func hasDownSounds(for group: String) -> Bool {
        !(down[group] ?? []).isEmpty
    }

    func build() -> SoundBank {
        let raw = order.map { (name: $0, down: down[$0] ?? [], up: up[$0] ?? []) }
        return SoundBank(id: id, name: name, gain: gain, samples: samples, groups: raw, mapping: mapping)
    }
}
