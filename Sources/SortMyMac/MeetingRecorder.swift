@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import AppKit
import CoreAudio
import QuartzCore
import SortMyMacCore

struct MicrophoneChoice: Identifiable { let id: AudioDeviceID; let name: String }

@MainActor
final class MeetingRecorder: NSObject {
    private var engine: AVAudioEngine?
    private var stream: SCStream?
    private var sink: RecordingSink?
    private var started: Double = 0
    private var pausedAt: Double?
    private var pausedDuration: Double = 0
    private var meterTimer: Timer?
    private var sleepObserver: NSObjectProtocol?
    private var deviceObserver: NSObjectProtocol?
    var onChunk: ((AudioChunk) -> Void)?
    var onError: ((String) -> Void)?
    var onMeter: ((Float, Float, Double) -> Void)?
    private(set) var running = false
    private(set) var paused = false

    static func microphones() -> [MicrophoneChoice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.compactMap { device in
            var streamsAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nil, &streamsSize) == noErr, streamsSize > 0 else { return nil }
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            _ = AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &name)
            return MicrophoneChoice(id: device, name: name?.takeUnretainedValue() as String? ?? "Microphone")
        }
    }
    func start(meeting: MeetingRecord, root: URL, microphoneID: AudioDeviceID) async throws {
        guard !running else { throw SortError.message("A meeting is already recording.") }
        if meeting.source != .system {
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw SortError.message("Allow microphone access in System Settings → Privacy & Security → Microphone.") }
        }
        let folder = try UtilityPaths.directory("Meetings/\(meeting.id.uuidString)", root: root)
        started = CACurrentMediaTime(); pausedDuration = 0; pausedAt = nil
        let sink = RecordingSink(folder: folder, epoch: started, chunk: { [weak self] chunk in Task { @MainActor in self?.onChunk?(chunk) } }, failure: { [weak self] error in Task { @MainActor in self?.onError?(error) } })
        self.sink = sink
        do {
            if meeting.source != .system {
                let engine = AVAudioEngine(), input = engine.inputNode
                if microphoneID != 0, let unit = input.audioUnit {
                    var device = microphoneID
                    guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout.size(ofValue: device))) == noErr else { throw SortError.message("Cannot select this microphone.") }
                }
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { throw SortError.message("Microphone has no input signal.") }
                input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
                    sink.receive(buffer, source: .microphone, time: time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : CACurrentMediaTime())
                }
                self.engine = engine
                try engine.start()
            }
            if meeting.source != .microphone {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else { throw SortError.message("No display is available for system audio capture.") }
                let config = SCStreamConfiguration()
                config.capturesAudio = true; config.excludesCurrentProcessAudio = true
                config.sampleRate = 48_000; config.channelCount = 1
                config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
                let stream = SCStream(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []), configuration: config, delegate: sink)
                try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
                self.stream = stream
                try await stream.startCapture()
            }
            running = true; paused = false
            if let engine { deviceObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in Task { @MainActor in
                guard let self, self.running else { return }; self.onError?("The microphone configuration changed. The recording was stopped and its completed audio was preserved.")
            } } }
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in Task { @MainActor in
                guard let self else { return }
                let levels = sink.levels()
                self.onMeter?(levels.0, levels.1, self.elapsed)
            } }
            sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.onError?("Recording was interrupted because this Mac went to sleep.") } }
        } catch {
            engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
            try? await stream?.stopCapture(); stream = nil
            await sink.finish(); self.sink = nil
            throw SortError.message("Recording could not start: \(error.localizedDescription). For system audio, allow Screen & System Audio Recording in Privacy & Security.")
        }
    }
    var elapsed: Double { max(0, (pausedAt ?? CACurrentMediaTime()) - started - pausedDuration) }
    func togglePause() async {
        guard running, let sink else { return }
        if paused {
            if let pausedAt { pausedDuration += CACurrentMediaTime() - pausedAt }
            pausedAt = nil; paused = false
            await sink.setPaused(false, offset: pausedDuration)
        } else {
            pausedAt = CACurrentMediaTime(); paused = true
            await sink.setPaused(true, offset: pausedDuration)
        }
    }
    func stop() async {
        guard sink != nil else { return }
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
        try? await stream?.stopCapture(); stream = nil
        await sink?.finish(); sink = nil
        meterTimer?.invalidate(); meterTimer = nil
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }; sleepObserver = nil
        if let deviceObserver { NotificationCenter.default.removeObserver(deviceObserver) }; deviceObserver = nil
        running = false; paused = false
    }
}

/// All filesystem writes and converters are confined to queue; audio callbacks copy then return.
final class RecordingSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.sortmymac.audio.writer", qos: .userInitiated)
    private let folder: URL, epoch: Double
    private let chunkCallback: @Sendable (AudioChunk) -> Void
    private let failure: @Sendable (String) -> Void
    private var writers: [AudioSource: AVAudioFile] = [:]
    private var starts: [AudioSource: Double] = [:]
    private var durations: [AudioSource: Double] = [:]
    private var manifest: [AudioChunk] = []
    private var mic: Float = 0, system: Float = 0
    private let meterLock = NSLock()
    private var paused = false, failed = false
    private var offset = 0.0
    private let pendingLock = NSLock()
    private var pendingBuffers = 0
    private var overflowReported = false
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    init(folder: URL, epoch: Double, chunk: @escaping @Sendable (AudioChunk) -> Void, failure: @escaping @Sendable (String) -> Void) {
        self.folder = folder; self.epoch = epoch; chunkCallback = chunk; self.failure = failure
    }
    func receive(_ buffer: AVAudioPCMBuffer, source: AudioSource, time: Double) {
        pendingLock.lock()
        if pendingBuffers >= 64 {
            let report = !overflowReported; overflowReported = true; pendingLock.unlock()
            if report { failure("Audio storage could not keep up. Recording was interrupted; completed chunks are safe.") }; return
        }
        pendingBuffers += 1; pendingLock.unlock()
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { releaseBuffer(); return }
        copy.frameLength = buffer.frameLength
        let from = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList), to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in from.indices { if let src = from[i].mData, let dst = to[i].mData { memcpy(dst, src, Int(from[i].mDataByteSize)) } }
        let box = AudioBufferBox(copy)
        queue.async { defer { self.releaseBuffer() }; self.write(box.buffer, source: source, time: time) }
    }
    private func releaseBuffer() { pendingLock.lock(); pendingBuffers -= 1; pendingLock.unlock() }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description), let inputFormat = AVAudioFormat(streamDescription: asbd) else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else { return }
        write(buffer, source: .system, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
    }
    func stream(_ stream: SCStream, didStopWithError error: any Error) { failure("System audio capture stopped: \(error.localizedDescription)") }
    private func write(_ input: AVAudioPCMBuffer, source: AudioSource, time: Double) {
        guard !paused, !failed else { return }
        do {
            let capacity = AVAudioFrameCount(Double(input.frameLength) * 48000 / input.format.sampleRate + 8)
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity), let converter = AVAudioConverter(from: input.format, to: format) else { throw SortError.message("Audio device format is unsupported.") }
            var supplied = false, conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            guard status != .error else { throw conversionError ?? SortError.message("Audio conversion failed.") }
            if writers[source] == nil {
                let url = folder.appendingPathComponent("\(source.rawValue)-\(UUID().uuidString).caf")
                writers[source] = try AVAudioFile(forWriting: url, settings: format.settings)
                starts[source] = max(0, time - epoch - offset); durations[source] = 0
            }
            try writers[source]?.write(from: converted)
            durations[source, default: 0] += Double(converted.frameLength) / 48000
            let level = converted.floatChannelData.map { samples in (0..<Int(converted.frameLength)).reduce(Float(0)) { max($0, abs(samples[0][$1])) } } ?? 0
            meterLock.lock(); if source == .microphone { mic = level } else { system = level }; meterLock.unlock()
            if durations[source, default: 0] >= 5 { try flush(source) }
        } catch { failed = true; failure(error.localizedDescription) }
    }
    private func flush(_ source: AudioSource) throws {
        guard let url = writers[source]?.url else { return }
        writers.removeValue(forKey: source)
        let chunk = AudioChunk(source: source, url: url, start: starts[source, default: 0], duration: durations[source, default: 0])
        // Removing writer finalizes the CAF; manifest is committed before the app is notified.
        manifest.append(chunk)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        chunkCallback(chunk)
    }
    func levels() -> (Float, Float) { meterLock.lock(); defer { meterLock.unlock() }; let result = (mic, system); mic = 0; system = 0; return result }
    func setPaused(_ value: Bool, offset: Double) async { await withCheckedContinuation { continuation in queue.async {
        do { try self.flush(.microphone); try self.flush(.system) } catch { self.failure(error.localizedDescription) }
        self.paused = value; self.offset = offset; continuation.resume()
    } } }
    func finish() async { await withCheckedContinuation { continuation in queue.async {
        self.paused = true
        do { try self.flush(.microphone); try self.flush(.system) } catch { self.failure(error.localizedDescription) }
        continuation.resume()
    } } }
}
private final class AudioBufferBox: @unchecked Sendable { let buffer: AVAudioPCMBuffer; init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer } }
