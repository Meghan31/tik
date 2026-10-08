//
//  AudioOutput.swift
//  tik
//
//  Owns the AVAudioEngine that pulls audio from VoiceMixer.
//  Graph: AVAudioSourceNode (our mixer) -> main mixer -> output (system default device).
//
//  The graph is built once and left running while Tik is enabled. When the default output
//  device changes, the engine's configuration changes, or the Mac wakes, the whole engine is
//  thrown away and rebuilt (cheap: all voice state lives in VoiceMixer, not in the graph).
//

import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

struct OutputInfo {
    var running = false
    var deviceName = "Unknown"
    var isBluetooth = false
    var sampleRate: Double = 0
    var bufferFrames: UInt32 = 0
    var presentationLatency: Double = 0
    var rebuilds = 0
    var lastError: String?

    /// Buffer + device/stream latency. Excludes Tik's own queue time (measured separately).
    var estimatedOutputMs: Double {
        guard sampleRate > 0 else { return 0 }
        return (Double(bufferFrames) / sampleRate + presentationLatency) * 1000
    }
}

final class AudioOutput {
    private let mixer: VoiceMixer
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var pendingRebuild: DispatchWorkItem?
    private var recentRebuilds: [Date] = []
    private var info = OutputInfo()

    /// Whether the app wants sound right now (enabled or previewing).
    private(set) var wantsRunning = false
    var bufferFrames: UInt32 = 256
    var onChange: (() -> Void)?

    init(mixer: VoiceMixer) {
        self.mixer = mixer
        installDeviceListener()
    }

    var isRunning: Bool { engine?.isRunning ?? false }

    func start() {
        wantsRunning = true
        if engine == nil { build() }
    }

    func stop() {
        wantsRunning = false
        pendingRebuild?.cancel()
        teardown()
        onChange?()
    }

    /// Before sleep: release the device but remember that we want to run.
    func suspend() {
        pendingRebuild?.cancel()
        teardown()
        onChange?()
    }

    /// After wake / device changes.
    func resumeIfNeeded() {
        if wantsRunning && engine == nil { build() }
    }

    func rebuildSoon(after delay: Double = 0.3) {
        pendingRebuild?.cancel()
        // Guard against a device that keeps re-announcing configuration changes:
        // more than 6 rebuilds in 10 s backs off to one attempt every 5 s.
        let now = Date()
        recentRebuilds = recentRebuilds.filter { now.timeIntervalSince($0) < 10 } + [now]
        let wait = recentRebuilds.count > 6 ? max(delay, 5) : delay
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.teardown()
                if self.wantsRunning { self.build() } else { self.onChange?() }
            }
        }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    func currentInfo() -> OutputInfo {
        var i = info
        i.running = isRunning
        if let id = AudioOutput.defaultOutputDevice() {
            i.deviceName = AudioOutput.deviceName(id) ?? "Unknown device"
            i.isBluetooth = AudioOutput.isBluetooth(id)
        }
        if let engine, isRunning {
            i.presentationLatency = engine.outputNode.presentationLatency
        }
        return i
    }

    // MARK: Graph

    private func build() {
        let engine = AVAudioEngine()
        let output = engine.outputNode

        // Ask the output device for a small IO buffer (applies to this process only).
        let frames = AudioOutput.requestBufferFrames(bufferFrames)

        let hardwareRate = output.outputFormat(forBus: 0).sampleRate
        let rate = hardwareRate > 0 ? hardwareRate : SoundBank.standardRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            info.lastError = "Could not create an audio format at \(Int(rate)) Hz."
            onChange?()
            return
        }

        let source = AVAudioSourceNode(format: format,
                                       renderBlock: mixer.makeRenderBlock(sampleRateRatio: SoundBank.standardRate / rate))
        engine.attach(source)
        do {
            try engine.connectNode(source, to: engine.mainMixerNode, format: format)
        } catch {
            info.lastError = "Couldn't connect the audio graph: \(error.localizedDescription)"
            onChange?()
            return
        }
        engine.mainMixerNode.outputVolume = 1

        mixer.resetWhileStopped()
        engine.prepare()
        do {
            try engine.start()
        } catch {
            info.lastError = "Audio output failed to start: \(error.localizedDescription)"
            onChange?()
            return
        }

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rebuildSoon()
            }
        }

        self.engine = engine
        info.sampleRate = rate
        info.bufferFrames = frames
        info.rebuilds += 1
        info.lastError = nil
        onChange?()
    }

    private func teardown() {
        if let o = configObserver {
            NotificationCenter.default.removeObserver(o)
            configObserver = nil
        }
        engine?.stop()
        engine = nil
    }

    // MARK: Core Audio device helpers

    private func installDeviceListener() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rebuildSoon()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
                                                         DispatchQueue.main, block)
        if status == noErr { deviceListener = block }
    }

    /// Sets the default output device's IO buffer size for this process and returns what the
    /// device actually accepted (devices clamp to their own supported range).
    nonisolated static func requestBufferFrames(_ frames: UInt32) -> UInt32 {
        guard let device = defaultOutputDevice() else { return frames }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var requested = frames
        _ = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &requested)
        var actual: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &actual) == noErr, actual > 0 {
            return actual
        }
        return frames
    }

    nonisolated static func defaultOutputDevice() -> AudioObjectID? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    nonisolated static func deviceName(_ id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value = name?.takeRetainedValue() else { return nil }
        return value as String
    }

    nonisolated static func isBluetooth(_ id: AudioObjectID) -> Bool {
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
}

// MARK: - Render block

extension VoiceMixer {
    /// Built in a nonisolated context on purpose: the block runs on Core Audio's real-time
    /// thread and must not inherit main-actor isolation.
    nonisolated func makeRenderBlock(sampleRateRatio: Double) -> AVAudioSourceNodeRenderBlock {
        let mixer = self
        return { isSilence, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else {
                for buffer in buffers {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                isSilence.pointee = true
                return noErr
            }
            let silent = mixer.render(frames: frames, left: left, right: right, sampleRateRatio: sampleRateRatio)
            isSilence.pointee = ObjCBool(silent)
            return noErr
        }
    }
}
