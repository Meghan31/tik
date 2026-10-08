//
//  PackLibrary.swift
//  tik
//
//  Finding, loading, validating, importing and exporting sound packs.
//
//  Two on-disk forms, one in-memory form (SoundBank):
//
//   • Bundled  `name.tikpack`  single file: "TIKP" + u32 version + u32 header length
//                               + JSON header + raw 16-bit little-endian mono PCM.
//   • Folder   `Name/manifest.json` + audio files (wav/aiff/caf/m4a/mp3).
//                               The open, hand-editable format for custom packs.
//
//  Packs are data only. Nothing in a pack is ever executed.
//

import Foundation
import AVFoundation

// MARK: - Models

nonisolated enum PackSource: Hashable, Sendable {
    case bundled(URL)
    case folder(URL)
}

/// How a pack was made. Decides which section it appears in (recorded first).
nonisolated enum PackCategory: String, CaseIterable, Hashable, Sendable {
    case recorded, synthesized, custom

    var title: String {
        switch self {
        case .recorded: return "Recorded"
        case .synthesized: return "Synthesized"
        case .custom: return "Your Packs"
        }
    }

    var badge: String {
        switch self {
        case .recorded: return "Recorded"
        case .synthesized: return "Synth"
        case .custom: return "Custom"
        }
    }
}

nonisolated struct PackInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let summary: String
    let author: String
    let source: PackSource
    var category: PackCategory = .custom
    /// Keycap color for the pack chip, "#RRGGBB".
    var color: String? = nil

    var isBundled: Bool {
        if case .bundled = source { return true }
        return false
    }
}

nonisolated enum PackError: LocalizedError, Sendable {
    case unreadable(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let m): return m
        case .invalid(let m): return m
        }
    }
}

nonisolated struct TikpackClipRef: Decodable, Sendable {
    let group: String
    let phase: String
    let offset: Int
    let length: Int
}

nonisolated struct TikpackHeader: Decodable, Sendable {
    let schemaVersion: Int
    let id: String
    let name: String
    let author: String?
    let description: String?
    let sampleRate: Double
    let format: String
    let gain: Float?
    let clips: [TikpackClipRef]
    let category: String?
    let color: String?
    /// macOS key code (as a string) → group name, for per-row / per-key sounds.
    let mapping: [String: String]?
}

nonisolated struct FolderGroup: Codable, Sendable {
    var down: [String]?
    var up: [String]?
}

nonisolated struct FolderManifest: Codable, Sendable {
    var schemaVersion: Int?
    var id: String
    var name: String
    var author: String?
    var description: String?
    var version: String?
    var gain: Float?
    var groups: [String: FolderGroup]
    var mapping: [String: String]?
}

// MARK: - Library

nonisolated enum PackLibrary {
    /// Order of built-in packs: recorded styles first, then the synthesized ones.
    static let bundledOrder = [
        "rec.cardboard", "rec.cream", "rec.crystal-purple", "rec.japanese-black", "rec.milky-yellow",
        "rec.oreo", "rec.super-red", "rec.mechanical",
        "cream", "deep", "crisp", "click", "soft", "retro",
    ]

    private static func orderKey(_ id: String) -> String {
        id.hasPrefix("com.tik.pack.") ? String(id.dropFirst("com.tik.pack.".count)) : id
    }

    // Import limits
    static let maxFileBytes = 5 * 1024 * 1024
    static let maxClipSeconds = 3.0
    static let maxClips = 600
    static let maxTotalSeconds = 600.0
    static let audioExtensions: Set<String> = ["wav", "wave", "aif", "aiff", "caf", "m4a", "mp3"]

    /// ~/Library/Containers/<app>/Data/Library/Application Support/Tik/Packs (sandboxed)
    static var packsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Tik/Packs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Discovery

    static func discover() -> [PackInfo] {
        var bundled: [PackInfo] = []
        let urls = Bundle.main.urls(forResourcesWithExtension: "tikpack", subdirectory: nil) ?? []
        for url in urls {
            if let header = try? readTikpackHeader(at: url).header {
                bundled.append(PackInfo(id: header.id, name: header.name, summary: header.description ?? "",
                                        author: header.author ?? "Tik", source: .bundled(url),
                                        category: header.category == "recorded" ? .recorded : .synthesized,
                                        color: header.color))
            }
        }
        bundled.sort { a, b in
            if a.category != b.category {
                return a.category == .recorded
            }
            let ia = bundledOrder.firstIndex(of: orderKey(a.id)) ?? 99
            let ib = bundledOrder.firstIndex(of: orderKey(b.id)) ?? 99
            return ia == ib ? a.name < b.name : ia < ib
        }

        var custom: [PackInfo] = []
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: packsDirectory, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        for dir in dirs {
            let manifestURL = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let m = try? JSONDecoder().decode(FolderManifest.self, from: data) else { continue }
            if bundled.contains(where: { $0.id == m.id }) || custom.contains(where: { $0.id == m.id }) { continue }
            custom.append(PackInfo(id: m.id, name: m.name, summary: m.description ?? "",
                                   author: m.author ?? "Unknown", source: .folder(dir), category: .custom))
        }
        custom.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return bundled + custom
    }

    // MARK: Loading

    static func load(_ source: PackSource) throws -> SoundBank {
        switch source {
        case .bundled(let url): return try loadTikpack(at: url)
        case .folder(let url): return try loadFolder(at: url)
        }
    }

    static func readTikpackHeader(at url: URL) throws -> (header: TikpackHeader, data: Data, pcmStart: Int) {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw PackError.unreadable("Couldn't read \(url.lastPathComponent).")
        }
        guard data.count >= 12, data.prefix(4) == Data("TIKP".utf8) else {
            throw PackError.invalid("\(url.lastPathComponent) is not a Tik pack.")
        }
        let (version, headerLength) = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (UInt32, UInt32) in
            (UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)),
             UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self)))
        }
        let start = 12 + Int(headerLength)
        guard version == 1, start <= data.count else {
            throw PackError.invalid("\(url.lastPathComponent) uses an unsupported pack version.")
        }
        let header = try JSONDecoder().decode(TikpackHeader.self, from: data.subdata(in: 12..<start))
        return (header, data, start)
    }

    static func loadTikpack(at url: URL) throws -> SoundBank {
        let (header, data, pcmStart) = try readTikpackHeader(at: url)
        guard header.format == "s16le", header.sampleRate > 0 else {
            throw PackError.invalid("\(header.name): unsupported sample format.")
        }
        let totalSamples = (data.count - pcmStart) / 2
        var builder = SoundBankBuilder(id: header.id, name: header.name)
        builder.gain = header.gain ?? 1

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for ref in header.clips {
                guard ref.offset >= 0, ref.length > 1, ref.offset + ref.length <= totalSamples,
                      let clipPhase = parsePhase(ref.phase) else { continue }
                var clip = [Float](repeating: 0, count: ref.length)
                let byteStart = pcmStart + ref.offset * 2
                for i in 0..<ref.length {
                    let v = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: byteStart + i * 2, as: Int16.self))
                    clip[i] = Float(v) / 32768
                }
                if header.sampleRate != SoundBank.standardRate {
                    clip = resample(clip, from: header.sampleRate, to: SoundBank.standardRate)
                }
                builder.add(group: ref.group, phase: clipPhase, samples: clip)
            }
        }
        guard builder.hasDownSounds(for: KeyClass.alpha.rawValue) else {
            throw PackError.invalid("\(header.name) has no letter-key sounds.")
        }
        var mapping: [UInt16: String] = [:]
        for (key, group) in header.mapping ?? [:] {
            if let code = UInt16(key), Int(code) < MouseCode.tableSize { mapping[code] = group }
        }
        builder.mapping = mapping
        return builder.build()
    }

    static func loadFolder(at folder: URL) throws -> SoundBank {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw PackError.unreadable("No manifest.json in “\(folder.lastPathComponent)”.")
        }
        let manifest: FolderManifest
        do {
            manifest = try JSONDecoder().decode(FolderManifest.self, from: data)
        } catch {
            throw PackError.invalid("manifest.json in “\(folder.lastPathComponent)” is malformed: \(error.localizedDescription)")
        }
        guard !manifest.id.isEmpty, !manifest.name.isEmpty else {
            throw PackError.invalid("manifest.json needs an \"id\" and a \"name\".")
        }

        var builder = SoundBankBuilder(id: manifest.id, name: manifest.name)
        builder.gain = min(max(manifest.gain ?? 1, 0), 4)
        var clipCount = 0
        var problems: [String] = []
        let root = folder.standardizedFileURL.path

        for (group, files) in manifest.groups.sorted(by: { $0.key < $1.key }) {
            for (phase, list) in [(KeyPhase.down, files.down ?? []), (KeyPhase.up, files.up ?? [])] {
                for relative in list {
                    clipCount += 1
                    guard clipCount <= maxClips else {
                        throw PackError.invalid("Pack has more than \(maxClips) sounds.")
                    }
                    let url = folder.appendingPathComponent(relative).standardizedFileURL
                    guard url.path.hasPrefix(root + "/") else {
                        problems.append("\(relative): outside the pack folder")
                        continue
                    }
                    guard audioExtensions.contains(url.pathExtension.lowercased()) else {
                        problems.append("\(relative): not an audio file")
                        continue
                    }
                    do {
                        let samples = try readAudio(at: url)
                        builder.add(group: group, phase: phase, samples: prepareImported(samples))
                    } catch {
                        problems.append("\(relative): \(error.localizedDescription)")
                    }
                    if Double(builder.totalSamples) / SoundBank.standardRate > maxTotalSeconds {
                        throw PackError.invalid("Pack is longer than \(Int(maxTotalSeconds)) seconds of audio.")
                    }
                }
            }
        }

        var mapping: [UInt16: String] = [:]
        for (key, group) in manifest.mapping ?? [:] {
            if let code = UInt16(key), Int(code) < MouseCode.tableSize { mapping[code] = group }
        }
        builder.mapping = mapping

        guard builder.hasDownSounds(for: KeyClass.alpha.rawValue) else {
            let detail = problems.isEmpty ? "" : " First problem: \(problems[0])"
            throw PackError.invalid("“\(manifest.name)” needs at least one \"alpha\" down sound.\(detail)")
        }
        return builder.build()
    }

    private static func parsePhase(_ string: String) -> KeyPhase? {
        switch string {
        case "down": return .down
        case "up": return .up
        default: return nil
        }
    }

    // MARK: Import / export

    /// Validates a folder pack and copies it into Tik's Packs folder. Returns the new pack's info.
    static func importFolder(_ source: URL) throws -> PackInfo {
        let bank = try loadFolder(at: source)     // full validation before copying anything
        let fm = FileManager.default
        let safeName = bank.id.replacingOccurrences(of: "/", with: "-")
        let destination = packsDirectory.appendingPathComponent(safeName, isDirectory: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: source, to: destination)
        return PackInfo(id: bank.id, name: bank.name, summary: "", author: "", source: .folder(destination))
    }

    /// Writes a pack as an editable folder (manifest.json + WAVs) into the Packs folder.
    static func exportEditable(_ bank: SoundBank, summary: String) throws -> URL {
        let fm = FileManager.default
        let baseName = "\(bank.name) (Editable)"
        var folder = packsDirectory.appendingPathComponent(baseName, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: folder.path) {
            folder = packsDirectory.appendingPathComponent("\(baseName) \(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        var groups: [String: FolderGroup] = [:]
        for g in bank.groups {
            let dir = folder.appendingPathComponent("sounds/\(g.name)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var entry = FolderGroup(down: [], up: [])
            for (i, clip) in g.down.enumerated() {
                let rel = "sounds/\(g.name)/down-\(String(format: "%02d", i + 1)).wav"
                try writeWAV(clip, to: folder.appendingPathComponent(rel))
                entry.down?.append(rel)
            }
            for (i, clip) in g.up.enumerated() {
                let rel = "sounds/\(g.name)/up-\(String(format: "%02d", i + 1)).wav"
                try writeWAV(clip, to: folder.appendingPathComponent(rel))
                entry.up?.append(rel)
            }
            groups[g.name] = entry
        }

        let suffix = folder.lastPathComponent == baseName ? "" : "-\(n - 1)"
        let manifest = FolderManifest(schemaVersion: 1, id: bank.id + ".editable" + suffix,
                                      name: folder.lastPathComponent, author: NSFullUserName(),
                                      description: summary.isEmpty ? "Editable copy of \(bank.name)." : summary,
                                      version: "1.0.0", gain: bank.gain, groups: groups,
                                      mapping: ["49": "space", "36": "enter"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
        return folder
    }

    // MARK: Audio file helpers

    /// Reads any Core Audio–supported file into mono Float samples at the standard rate.
    static func readAudio(at url: URL, maxSeconds: Double = PackLibrary.maxClipSeconds,
                          maxBytes: Int = PackLibrary.maxFileBytes) throws -> [Float] {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes?[.size] as? NSNumber, size.intValue > maxBytes {
            throw PackError.invalid("file is larger than \(maxBytes / (1024 * 1024)) MB")
        }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(clamping: file.length)
        guard frames > 1 else { throw PackError.invalid("file is empty") }
        guard Double(frames) / format.sampleRate <= maxSeconds else {
            throw PackError.invalid("audio is longer than \(Int(maxSeconds)) seconds")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw PackError.invalid("couldn't allocate audio buffer")
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { throw PackError.invalid("unsupported audio format") }
        let n = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<channelCount {
            let p = channels[c]
            for i in 0..<n { mono[i] += p[i] }
        }
        if channelCount > 1 {
            let scale = 1 / Float(channelCount)
            for i in 0..<n { mono[i] *= scale }
        }
        return resample(mono, from: format.sampleRate, to: SoundBank.standardRate)
    }

    /// Trims leading silence (it would feel like latency), and fades the tail to avoid clicks.
    static func prepareImported(_ input: [Float]) -> [Float] {
        guard input.count > 8 else { return input }
        var peak: Float = 0
        for x in input { peak = max(peak, abs(x)) }
        guard peak > 0 else { return input }
        let threshold = peak * 0.003            // about -50 dB below the peak
        var first = 0
        while first < input.count && abs(input[first]) < threshold { first += 1 }
        let preRoll = 24                        // keep 0.5 ms before the transient
        let start = max(0, first - preRoll)
        var out = Array(input[start...])
        let fadeIn = min(first - start, out.count)
        if fadeIn > 1 {
            for i in 0..<fadeIn { out[i] *= Float(i) / Float(fadeIn) }
        }
        let fadeOut = min(240, out.count / 4)   // 5 ms
        if fadeOut > 1 {
            for i in 0..<fadeOut {
                out[out.count - fadeOut + i] *= 1 - Float(i + 1) / Float(fadeOut)
            }
        }
        return out
    }

    static func resample(_ x: [Float], from source: Double, to target: Double) -> [Float] {
        guard source > 0, target > 0, abs(source - target) > 0.5, x.count > 1 else { return x }
        let ratio = source / target
        let n = Int(Double(x.count - 1) / ratio) + 1
        var y = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let p = Double(i) * ratio
            let j = Int(p)
            let f = Float(p - Double(j))
            let a = x[j]
            let b = j + 1 < x.count ? x[j + 1] : a
            y[i] = a + (b - a) * f
        }
        return y
    }

    static func writeWAV(_ clip: Clip, to url: URL) throws {
        try writeWAV(samples: Array(UnsafeBufferPointer(start: clip.samples, count: clip.count)), to: url)
    }

    static func writeWAV(samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: SoundBank.standardRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: SoundBank.standardRate, channels: 1),
              samples.count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { throw PackError.invalid("couldn't allocate audio buffer") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { channel.update(from: base, count: src.count) }
        }
        try file.write(from: buffer)
    }
}
