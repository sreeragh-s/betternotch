@preconcurrency import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

public struct MediaInfo: Sendable {
    public let duration: Double
    public let hasVideo: Bool
    public let hasAudio: Bool
    public let width: Int
    public let height: Int
}
public enum MediaProcessor {
    public static func info(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw SortError.message("Media has no finite playable duration.") }
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        var size = CGSize.zero
        if let track = video.first { size = try await track.load(.naturalSize).applying(track.load(.preferredTransform)) }
        return MediaInfo(duration: duration, hasVideo: !video.isEmpty, hasAudio: !audio.isEmpty, width: Int(abs(size.width)), height: Int(abs(size.height)))
    }
    public static func range(settings: ActionSettings, duration: Double) throws -> CMTimeRange {
        let end = settings.end > 0 ? settings.end : duration
        guard settings.start.isFinite, end.isFinite, settings.start >= 0, end <= duration + 0.001, end > settings.start else { throw SortError.message("Choose start and end points inside the clip, with end after start.") }
        return CMTimeRange(start: CMTime(seconds: settings.start, preferredTimescale: 60_000), end: CMTime(seconds: min(end, duration), preferredTimescale: 60_000))
    }
    public static func render(_ input: URL, kind: FileActionKind, settings: ActionSettings, to output: URL) async throws {
        let details = try await info(input)
        if !details.hasVideo && ["mp4", "mov"].contains(settings.format) { throw SortError.message("Choose M4A, WAV, or AIFF for audio-only input.") }
        let timeRange = try range(settings: settings, duration: details.duration)
        let asset = AVURLAsset(url: input)
        if kind == .makeGIF { try await gif(asset, range: timeRange, to: output); return }
        if ["wav", "aiff"].contains(settings.format) { try await pcm(asset, range: timeRange, aiff: settings.format == "aiff", to: output); return }
        let audioOnly = kind == .extractAudio || settings.format == "m4a" || !details.hasVideo
        if audioOnly && !details.hasAudio { throw SortError.message("This clip has no audio track.") }
        let exportAsset: AVAsset
        if audioOnly {
            let composition = AVMutableComposition()
            guard let track = try await asset.loadTracks(withMediaType: .audio).first,
                  let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw SortError.message("No audio track is available.") }
            try destination.insertTimeRange(timeRange, of: track, at: .zero); exportAsset = composition
        } else { exportAsset = asset }
        let preset: String
        if audioOnly { preset = AVAssetExportPresetAppleM4A }
        else { preset = settings.mediaPreset == "1080p" ? AVAssetExportPreset1920x1080 : settings.mediaPreset == "original" ? AVAssetExportPresetHighestQuality : AVAssetExportPreset1280x720 }
        guard let session = AVAssetExportSession(asset: exportAsset, presetName: preset) else { throw SortError.message("This media format cannot be exported on this Mac.") }
        let fileType: AVFileType = audioOnly ? .m4a : settings.format == "mov" ? .mov : .mp4
        guard session.supportedFileTypes.contains(fileType) else { throw SortError.message("Selected container is not supported for this clip.") }
        session.outputURL = output; session.outputFileType = fileType
        if !audioOnly { session.timeRange = timeRange }
        session.shouldOptimizeForNetworkUse = true
        let exportBox = MediaExportBox(session)
        try await withTaskCancellationHandler {
            await exportBox.perform()
            try Task.checkCancellation()
            guard session.status == .completed else { throw session.error ?? SortError.message("Media export did not complete.") }
        } onCancel: { exportBox.cancel() }
        let result = try await info(output)
        guard abs(result.duration - timeRange.duration.seconds) < 0.15 else { throw SortError.message("Export duration did not match the selected interval.") }
    }
    private static func gif(_ asset: AVAsset, range: CMTimeRange, to output: URL) async throws {
        guard range.duration.seconds <= 20 else { throw SortError.message("GIF selection is limited to 20 seconds. Choose a shorter interval.") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let count = max(1, Int(range.duration.seconds * 10))
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else { throw SortError.message("Cannot create GIF.") }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for index in 0..<count {
            try Task.checkCancellation()
            let time = CMTimeAdd(range.start, CMTime(seconds: Double(index) / 10, preferredTimescale: 60000))
            let (image, _) = try await generator.image(at: time)
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw SortError.message("GIF encoding failed.") }
    }
    private static func pcm(_ asset: AVAsset, range: CMTimeRange, aiff: Bool, to output: URL) async throws {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw SortError.message("No audio track is available.") }
        let reader = try AVAssetReader(asset: asset); reader.timeRange = range
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: aiff]
        let source = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(source)
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true)!
        let file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        guard reader.startReading() else { throw reader.error ?? SortError.message("Cannot decode audio.") }
        while let sample = source.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let frames = CMSampleBufferGetNumSamples(sample)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { throw SortError.message("Cannot allocate audio buffer.") }
            buffer.frameLength = AVAudioFrameCount(frames)
            guard let bytes = buffer.int16ChannelData?[0] else { continue }
            let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: CMBlockBufferGetDataLength(block), destination: bytes)
            guard status == kCMBlockBufferNoErr else { throw SortError.message("Cannot decode audio samples.") }
            try file.write(from: buffer)
        }
        guard reader.status == .completed else { throw reader.error ?? SortError.message("Audio decoding failed.") }
    }
    public static func waveform(_ url: URL, bins: Int = 180) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { return [] }
        var peaks = [Float](repeating: 0, count: bins)
        let length = max(1, file.length)
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let start = file.framePosition
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { break }
            for index in 0..<Int(buffer.frameLength) {
                let bin = min(bins - 1, Int((start + Int64(index)) * Int64(bins) / length))
                peaks[bin] = max(peaks[bin], abs(channel[index]))
            }
        }
        return peaks
    }
}

private final class MediaExportBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
    func perform() async { await withCheckedContinuation { continuation in session.exportAsynchronously { continuation.resume() } } }
    func cancel() { session.cancelExport() }
}
