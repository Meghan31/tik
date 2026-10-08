//
//  Random.swift
//  tik
//
//  Cheap deterministic randomness for the real-time path (no syscalls, no allocation).
//

import Foundation

nonisolated struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [-1, 1).
    mutating func bipolar() -> Float {
        Float(next() >> 40) / Float(1 << 24) * 2 - 1
    }
}

/// Plays every variant once before repeating, and never the same variant twice in a row.
nonisolated struct ShuffleBag: Sendable {
    private var order: [Int]
    private var index: Int
    private var last = -1

    init(count: Int) {
        order = Array(0..<max(count, 0))
        index = order.count   // forces a shuffle on first use
    }

    var count: Int { order.count }

    mutating func next(using rng: inout SplitMix64) -> Int {
        let n = order.count
        if n <= 1 { return 0 }
        if index >= n {
            var i = n - 1
            while i > 0 {
                let j = Int(rng.next() % UInt64(i + 1))
                order.swapAt(i, j)
                i -= 1
            }
            if order[0] == last { order.swapAt(0, n - 1) }
            index = 0
        }
        let v = order[index]
        index += 1
        last = v
        return v
    }
}
