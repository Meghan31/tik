//
//  PackBuilderView.swift
//  tik
//
//  "Make Your Own Pack": drop or pick audio files per key type, try the result by typing
//  anywhere, then save it as a normal (editable) Tik pack.
//

import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
@Observable
final class PackBuilderModel {
    var name = "My Keyboard"
    var generateReleases = true
    var evenOut = true
    private(set) var slots: [BuilderSlotKind: SlotAudio] = [:]
    private(set) var busy: Set<BuilderSlotKind> = []
    private(set) var isSaving = false
    private(set) var revision = 0
    var message: String?

    func audio(_ kind: BuilderSlotKind) -> SlotAudio {
        slots[kind] ?? SlotAudio()
    }

    var hasSounds: Bool {
        slots.values.contains { !$0.downs.isEmpty }
    }

    var totalClips: Int {
        slots.values.reduce(0) { $0 + $1.downs.count + $1.ups.count }
    }

    func add(_ urls: [URL], to kind: BuilderSlotKind, asReleases: Bool) {
        let files = urls.filter { $0.isFileURL }
        guard !files.isEmpty else { return }
        busy.insert(kind)
        message = nil
        Task.detached(priority: .userInitiated) {
            let result = PackAssembler.process(files, asReleases: asReleases)
            await MainActor.run {
                self.merge(result, into: kind)
            }
        }
    }

    private func merge(_ result: UploadResult, into kind: BuilderSlotKind) {
        busy.remove(kind)
        var current = slots[kind] ?? SlotAudio()
        current.downs = Array((current.downs + result.audio.downs).prefix(PackAssembler.maxClipsPerPhase))
        current.ups = Array((current.ups + result.audio.ups).prefix(PackAssembler.maxClipsPerPhase))
        current.sources += result.audio.sources
        slots[kind] = current.isEmpty ? nil : current
        if !result.problems.isEmpty {
            message = result.problems.joined(separator: "\n")
        } else if result.audio.isEmpty {
            message = "No usable sound was found in that file."
        }
        revision += 1
    }

    func clear(_ kind: BuilderSlotKind) {
        slots[kind] = nil
        revision += 1
    }

    func optionsChanged() {
        revision += 1
    }

    func assembled() -> AssembledPack? {
        PackAssembler.assemble(name: name, slots: slots, generateReleases: generateReleases, evenOut: evenOut)
    }

    /// Writes the pack to disk. Returns its id on success.
    func save() async -> String? {
        guard let pack = assembled() else {
            message = "Add at least one sound first."
            return nil
        }
        isSaving = true
        let result = await Task.detached(priority: .userInitiated) {
            Result { try PackAssembler.write(pack) }
        }.value
        isSaving = false
        switch result {
        case .success:
            return pack.id
        case .failure(let error):
            message = "Couldn't save: \(error.localizedDescription)"
            return nil
        }
    }
}

struct PackBuilderView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var builder = PackBuilderModel()
    @State private var targeted: BuilderSlotKind?
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Make Your Own Pack")
                    .font(.title2.weight(.semibold))
                Text("Drop audio files onto a key type, or use Add. One file can hold many presses: record yourself pressing a key 8–10 times, slowly, and Tik finds every press and release. Empty rows borrow from Letters.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Pack name", text: $builder.name)
                .textFieldStyle(.roundedBorder)
                .font(.title3)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(BuilderSlotKind.allCases) { kind in
                        slotRow(kind)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Create release sounds when you only provide presses", isOn: $builder.generateReleases)
                Toggle("Even out loudness between clips", isOn: $builder.evenOut)
            }
            .onChange(of: builder.generateReleases) { _, _ in builder.optionsChanged() }
            .onChange(of: builder.evenOut) { _, _ in builder.optionsChanged() }

            if let message = builder.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    tryIt(play: true)
                } label: {
                    Label("Try It", systemImage: "play.fill")
                }
                .disabled(!builder.hasSounds)
                if app.isAuditioning {
                    Text("Type anywhere to hear your pack")
                        .font(.callout)
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(builder.isSaving ? "Saving…" : "Save Pack") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!builder.hasSounds || builder.isSaving || !builder.busy.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 660, height: 680)
        .onChange(of: builder.revision) { _, _ in
            if app.isAuditioning { tryIt(play: false) }
        }
        .onDisappear {
            if !saved { app.endAudition() }
        }
    }

    // MARK: Rows

    private func slotRow(_ kind: BuilderSlotKind) -> some View {
        let audio = builder.audio(kind)
        let isTarget = targeted == kind
        return HStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.system(size: 16))
                .frame(width: 26)
                .foregroundStyle(audio.isEmpty ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.body.weight(.medium))
                Text(summary(kind, audio))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if builder.busy.contains(kind) {
                ProgressView().controlSize(.small)
            }
            if !audio.isEmpty {
                Button {
                    tryIt(play: false)
                    app.playTestKey(kind.testKeyCode)
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
                .help("Play")
                Button {
                    builder.clear(kind)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove these sounds")
            }
            Menu("Add") {
                Button("Presses or a recording…") { pick(kind, asReleases: false) }
                Button("Release sounds only…") { pick(kind, asReleases: true) }
            }
            .fixedSize()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isTarget ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isTarget ? Color.accentColor : Color.clear,
                              style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        )
        .dropDestination(for: URL.self) { urls, _ in
            builder.add(urls, to: kind, asReleases: false)
            return true
        } isTargeted: { inside in
            if inside {
                targeted = kind
            } else if targeted == kind {
                targeted = nil
            }
        }
    }

    private func summary(_ kind: BuilderSlotKind, _ audio: SlotAudio) -> String {
        if audio.isEmpty {
            if kind == .alpha { return "Drop sounds here. These play for every key that has none of its own." }
            if kind == .mouse { return "Optional. Clicks stay silent without sounds here." }
            return "Optional. Uses Letters until you add sounds."
        }
        var parts = ["\(audio.downs.count) press\(audio.downs.count == 1 ? "" : "es")"]
        if audio.ups.isEmpty {
            parts.append(builder.generateReleases ? "releases created automatically" : "no releases")
        } else {
            parts.append("\(audio.ups.count) release\(audio.ups.count == 1 ? "" : "s")")
        }
        if let first = audio.sources.first {
            parts.append(audio.sources.count > 1 ? "from \(first) +\(audio.sources.count - 1)" : "from \(first)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func pick(_ kind: BuilderSlotKind, asReleases: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Add"
        panel.message = asReleases
            ? "Choose key-release sounds for \(kind.title)"
            : "Choose sounds for \(kind.title). A recording with several presses is fine."
        guard panel.runModal() == .OK else { return }
        builder.add(panel.urls, to: kind, asReleases: asReleases)
    }

    private func tryIt(play: Bool) {
        guard let pack = builder.assembled() else { return }
        app.audition(PackAssembler.makeBank(pack))
        if play { app.playPreview() }
    }

    private func save() async {
        guard let id = await builder.save() else { return }
        saved = true
        app.didSaveBuiltPack(id: id)
        dismiss()
    }
}
