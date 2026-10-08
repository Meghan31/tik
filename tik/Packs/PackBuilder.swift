//
//  PackBuilder.swift
//  tik
//
//  Turns sounds the user uploads into a Tik pack.
//
//  • SoundSlicer finds every individual click in a file. A recording of one key pressed
//    ten times becomes ten press clips (and ten release clips, if it can tell them apart).
//  • PackAssembler evens out loudness, creates release sounds when none were given,
//    normalizes the pack, and writes it in the open folder format (manifest.json + WAVs).
//
//  Pure Swift, no UI, runs off the main thread. Mirrors tools/slicer.py (tuned on test recordings).
//

import Foundation

// MARK: - Slots

/// The key types a user can give sounds to. Raw values are pack group names.
nonisolated enum BuilderSlotKind: String, CaseIterable, Identifiable, Sendable {
    case alpha, space, enter, backspace, wide, modifier, mouse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alpha: return "Letters & numbers"
        case .space: return "Space bar"
        case .enter: return "Return"
        case .backspace: return "Delete"
        case .wide: return "Shift, Tab, Caps Lock"
        case .modifier: return "⌘ ⌥ ⌃ fn"
        case .mouse: return "Mouse click"
        }
    }

    var symbol: String {
        switch self {
        case .alpha: return "textformat.abc"
        case .space: return "space"
        case .enter: return "return"
        case .backspace: return "delete.left"
        case .wide: return "shift"
        case .modifier: return "command"
        case .mouse: return "computermouse"
        }
    }

    /// Key used to audition this slot.
    var testKeyCode: UInt16 {
        switch self {
        case .alpha: return 0
        case .space: return 49
        case .enter: return 36
        case .backspace: return 51
        case .wide: return 56
        case .modifier: return 55
        case .mouse: return MouseCode.left
        }
    }
}

nonisolated struct SlotAudio: Sendable {
    var downs: [[Float]] = []
    var ups: [[Float]] = []
    var sources: [String] = []

    var isEmpty: Bool { downs.isEmpty && ups.isEmpty }
}

nonisolated struct UploadResult: Sendable {
    var audio = SlotAudio()
    var problems: [String] = []
}

// MARK: - Slicer

nonisolated struct SlicedHit: Sendable, Equatable {
    let start: Int
    let end: Int
}

nonisolated enum SoundSlicer {
    static let hop = 96                 // 2 ms
    static let window = 480             // 10 ms, long enough for a low "thock"
    static let minGapFrames = 18        // 36 ms between onsets
    static let riseDB: Float = 9
    static let tailFrames = 10          // 20 ms of quiet ends a hit
    static let maxHit = 48_000          // 1 s
    static let minHit = 576             // 12 ms
    static let preRoll = 48             // 1 ms
    static let maxWhole = 96_000        // a file with no clear clicks is used whole, up to 2 s

    /// Energy (dB) of a 10 ms window starting at every 2 ms hop.
    static func frameEnergy(_ x: [Float]) -> [Float] {
        guard x.count >= window else { return [] }
        let n = (x.count - window) / hop + 1
        var prefix = [Double](repeating: 0, count: x.count + 1)
        for i in 0..<x.count {
            let v = Double(x[i])
            prefix[i + 1] = prefix[i] + v * v
        }
        var out = [Float](repeating: -120, count: n)
        for k in 0..<n {
            let a = k * hop
            out[k] = Float(10 * log10((prefix[a + window] - prefix[a]) / Double(window) + 1e-12))
        }
        return out
    }

    static func findHits(_ x: [Float]) -> [SlicedHit] {
        let whole = [SlicedHit(start: 0, end: min(x.count, maxWhole))]
        let e = frameEnergy(x)
        let n = e.count
        guard n >= 4 else { return whole }
        let sorted = e.sorted()
        let floor = sorted[Int(Float(n - 1) * 0.15)]
        let peak = sorted[n - 1]
        guard peak - floor >= 15 else { return whole }
        let threshold = max(floor + 12, peak - 40)

        var onsets: [Int] = []
        var last = -10_000
        for k in 0..<n {
            if e[k] < threshold || k - last < minGapFrames { continue }
            let previous = k > 0 ? (e[max(0, k - 8)..<k].min() ?? floor) : floor
            if e[k] - previous >= riseDB {
                onsets.append(k)
                last = k
            }
        }
        guard !onsets.isEmpty else { return whole }

        // Refine each onset to the first sample above 30% of the local peak.
        var starts: [Int] = []
        for k in onsets {
            let a = k * hop
            let b = min(x.count, a + window + 2 * hop)
            var local: Float = 0
            for i in a..<b { local = max(local, abs(x[i])) }
            var p = a
            while p < b && abs(x[p]) < 0.3 * local { p += 1 }
            starts.append(max(0, p - preRoll))
        }

        var hits: [SlicedHit] = []
        for i in 0..<starts.count {
            let start = starts[i]
            let hardEnd = i + 1 < starts.count ? starts[i + 1] : x.count
            var end = hardEnd
            var quiet = 0
            var j = start / hop + 5
            while j < n && j * hop < hardEnd {
                if e[j] < floor + 6 {
                    quiet += 1
                    if quiet >= tailFrames {
                        end = (j - tailFrames + 1) * hop + window / 2
                        break
                    }
                } else {
                    quiet = 0
                }
                j += 1
            }
            end = min(end, hardEnd, start + maxHit, x.count)
            if end - start >= minHit { hits.append(SlicedHit(start: start, end: end)) }
        }
        return hits.isEmpty ? whole : hits
    }

    /// RMS level of the first 20 ms, in dB.
    static func attackLevel(_ clip: [Float]) -> Float {
        let n = min(clip.count, 960)
        guard n > 0 else { return -120 }
        var sum: Float = 0
        for i in 0..<n { sum += clip[i] * clip[i] }
        return 10 * log10(sum / Float(n) + 1e-12)
    }

    /// Splits a recording into press sounds and, when it can pair them, release sounds.
    static func slice(_ x: [Float]) -> (downs: [[Float]], ups: [[Float]]) {
        let hits = findHits(x)
        let clips = hits.map { Array(x[$0.start..<$0.end]) }
        let levels = clips.map(attackLevel)
        let n = clips.count
        var pairs: [(Int, Int)] = []
        var singles: [Int] = []
        var i = 0
        while i < n {
            if i + 1 < n, hits[i + 1].start - hits[i].start <= 14_400, levels[i + 1] <= levels[i] - 2 {
                pairs.append((i, i + 1))
                i += 2
            } else {
                singles.append(i)
                i += 1
            }
        }
        if pairs.count >= 2 && Double(pairs.count * 2) >= 0.6 * Double(n) {
            let downs = pairs.map { clips[$0.0] } + singles.map { clips[$0] }
            let ups = pairs.map { clips[$0.1] }
            return (downs, ups)
        }
        return (clips, [])
    }
}

// MARK: - Assembly

nonisolated struct AssembledGroup: Sendable {
    let name: String
    let downs: [[Float]]
    let ups: [[Float]]
}

nonisolated struct AssembledPack: Sendable {
    let id: String
    let name: String
    let groups: [AssembledGroup]

    var clipCount: Int { groups.reduce(0) { $0 + $1.downs.count + $1.ups.count } }
}

nonisolated enum PackAssembler {
    static let maxClipsPerPhase = 48
    static let maxUploadSeconds = 60.0
    static let maxUploadBytes = 50 * 1024 * 1024

    /// Reads, slices and cleans up uploaded files. `asReleases` puts every hit into the release list.
    static func process(_ urls: [URL], asReleases: Bool) -> UploadResult {
        var result = UploadResult()
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let samples = try PackLibrary.readAudio(at: url, maxSeconds: maxUploadSeconds, maxBytes: maxUploadBytes)
                let sliced = SoundSlicer.slice(samples)
                let downs = sliced.downs.map(PackLibrary.prepareImported).filter { $0.count > 240 }
                let ups = sliced.ups.map(PackLibrary.prepareImported).filter { $0.count > 240 }
                if asReleases {
                    result.audio.ups += downs + ups
                } else {
                    result.audio.downs += downs
                    result.audio.ups += ups
                }
                result.audio.sources.append(url.lastPathComponent)
            } catch {
                result.problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        result.audio.downs = Array(result.audio.downs.prefix(maxClipsPerPhase))
        result.audio.ups = Array(result.audio.ups.prefix(maxClipsPerPhase))
        return result
    }

    /// A believable key-up from a key-down: shorter, brighter, about 10 dB quieter.
    static func syntheticRelease(from down: [Float]) -> [Float] {
        let n = min(down.count, max(480, Int(Double(down.count) * 0.6)), 4_800)
        guard n > 1 else { return down }
        let rc = 1.0 / (2.0 * Double.pi * 900.0)
        let dt = 1.0 / SoundBank.standardRate
        let a = Float(rc / (rc + dt))
        var y = [Float](repeating: 0, count: n)
        var previousIn: Float = 0
        var previousOut: Float = 0
        for i in 0..<n {
            let xi = down[i]
            let yi = a * (previousOut + xi - previousIn)
            y[i] = yi * 0.32
            previousIn = xi
            previousOut = yi
        }
        let fade = max(2, Int(Double(n) * 0.3))
        for i in 0..<fade {
            y[n - fade + i] *= 1 - Float(i + 1) / Float(fade)
        }
        return y
    }

    /// Pulls every clip in a group 70% of the way toward the group's median level (max ±6 dB).
    static func balance(_ clips: [[Float]]) -> [[Float]] {
        guard clips.count > 1 else { return clips }
        let levels = clips.map(SoundSlicer.attackLevel)
        let median = levels.sorted()[levels.count / 2]
        var out: [[Float]] = []
        for (clip, level) in zip(clips, levels) {
            let correction = max(-6, min(6, (median - level) * 0.7))
            let gain = powf(10, correction / 20)
            out.append(clip.map { $0 * gain })
        }
        return out
    }

    static func peak(_ clip: [Float]) -> Float {
        var p: Float = 0
        for v in clip { p = max(p, abs(v)) }
        return p
    }

    static func assemble(name: String, slots: [BuilderSlotKind: SlotAudio],
                         generateReleases: Bool, evenOut: Bool) -> AssembledPack? {
        // Letters are the fallback for every other key, so they must exist.
        // If the user only filled another row, that row's sounds play for letters too.
        var filled = slots.filter { !$0.value.downs.isEmpty }
        if filled[.alpha] == nil {
            guard let donor = BuilderSlotKind.allCases.first(where: { filled[$0] != nil && $0 != .mouse })
                    ?? BuilderSlotKind.allCases.first(where: { filled[$0] != nil }),
                  let audio = filled[donor] else { return nil }
            filled[.alpha] = audio
        }

        var groups: [AssembledGroup] = []
        for kind in BuilderSlotKind.allCases {
            guard let audio = filled[kind] else { continue }
            var downs = evenOut ? balance(audio.downs) : audio.downs
            var ups = evenOut ? balance(audio.ups) : audio.ups
            if ups.isEmpty && generateReleases { ups = downs.map(syntheticRelease) }
            downs = Array(downs.prefix(maxClipsPerPhase))
            ups = Array(ups.prefix(maxClipsPerPhase))
            groups.append(AssembledGroup(name: kind.rawValue, downs: downs, ups: ups))
        }

        // Normalize: typical letter press peaks around -4 dBFS, nothing above -0.5 dBFS.
        let reference = groups.first(where: { $0.name == KeyClass.alpha.rawValue })?.downs.map(peak).sorted()
        let typical = reference.flatMap { $0.isEmpty ? nil : $0[$0.count / 2] } ?? 0
        let loudest = groups.flatMap { $0.downs + $0.ups }.map(peak).max() ?? 0
        var gain: Float = typical > 0 ? powf(10, -4.0 / 20) / typical : 1
        if loudest * gain > 0.944 { gain = 0.944 / max(loudest, 1e-6) }
        let scaled = groups.map { g in
            AssembledGroup(name: g.name, downs: g.downs.map { c in c.map { $0 * gain } },
                           ups: g.ups.map { c in c.map { $0 * gain } })
        }

        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = cleanName.isEmpty ? "My Pack" : cleanName
        let slug = finalName.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let id = "com.tik.user.\(slug).\(Int(Date().timeIntervalSince1970))"
        return AssembledPack(id: id, name: finalName, groups: scaled)
    }

    /// In-memory bank for auditioning before saving.
    static func makeBank(_ pack: AssembledPack) -> SoundBank {
        var builder = SoundBankBuilder(id: pack.id, name: pack.name)
        for g in pack.groups {
            for clip in g.downs { builder.add(group: g.name, phase: .down, samples: clip) }
            for clip in g.ups { builder.add(group: g.name, phase: .up, samples: clip) }
        }
        return builder.build()
    }

    /// Writes the pack into Tik's Packs folder in the open folder format. Returns the folder.
    static func write(_ pack: AssembledPack) throws -> URL {
        let fm = FileManager.default
        let safeName = pack.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var folder = PackLibrary.packsDirectory.appendingPathComponent(safeName, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: folder.path) {
            folder = PackLibrary.packsDirectory.appendingPathComponent("\(safeName) \(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        var groups: [String: FolderGroup] = [:]
        for g in pack.groups {
            let dir = folder.appendingPathComponent("sounds/\(g.name)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var entry = FolderGroup(down: [], up: [])
            for (i, clip) in g.downs.enumerated() {
                let rel = "sounds/\(g.name)/down-\(String(format: "%02d", i + 1)).wav"
                try PackLibrary.writeWAV(samples: clip, to: folder.appendingPathComponent(rel))
                entry.down?.append(rel)
            }
            for (i, clip) in g.ups.enumerated() {
                let rel = "sounds/\(g.name)/up-\(String(format: "%02d", i + 1)).wav"
                try PackLibrary.writeWAV(samples: clip, to: folder.appendingPathComponent(rel))
                entry.up?.append(rel)
            }
            groups[g.name] = entry
        }
        let manifest = FolderManifest(schemaVersion: 1, id: pack.id, name: pack.name, author: NSFullUserName(),
                                      description: "Made with Tik from your own sounds.", version: "1.0.0",
                                      gain: 1, groups: groups, mapping: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
        return folder
    }
}
