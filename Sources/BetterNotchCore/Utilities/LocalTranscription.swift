@preconcurrency import AVFoundation
import CryptoKit
import Darwin
import Foundation

public struct SpeechModel: Identifiable, Sendable {
    public let id: String
    public let bytes: Int64
    public let sha256: String
    public var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(id).bin")! }
    public static let choices = [
        SpeechModel(id: "small", bytes: 487_601_967, sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"),
        SpeechModel(id: "base", bytes: 147_951_465, sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe")
    ]
}
public actor SpeechModels {
    let root: URL
    public init(root: URL = UtilityPaths.root) { self.root = root }
    public func installed(_ id: String) -> URL? {
        let url = root.appendingPathComponent("Models/ggml-\(id).bin")
        guard let model = SpeechModel.choices.first(where: { $0.id == id }),
              (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(model.bytes) else { return nil }
        return url
    }
    public func install(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let model = SpeechModel.choices.first(where: { $0.id == id }) else { throw SortError.message("Unknown speech model.") }
        let folder = try UtilityPaths.directory("Models", root: root)
        let delegate = DownloadDelegate(destination: folder.appendingPathComponent(".download-\(UUID().uuidString)"), progress: progress)
        let downloaded = try await withTaskCancellationHandler { try await delegate.download(model.url) } onCancel: { delegate.cancel() }
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try Task.checkCancellation()
        guard try LocalFileOperations().digest(downloaded) == model.sha256 else { throw SortError.message("Speech model checksum did not match. Download it again.") }
        let target = folder.appendingPathComponent("ggml-\(id).bin")
        if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: downloaded) }
        else { try FileManager.default.moveItem(at: downloaded, to: target) }
        return target
    }
    public func remove(_ id: String) throws { if let url = installed(id) { try FileManager.default.removeItem(at: url) } }
}
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL, progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var canceled = false
    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) { self.destination = destination; self.progress = progress }
    func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); defer { lock.unlock() }
            guard !canceled else { continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.downloadTask(with: url); self.task = task; task.resume()
        }
    }
    func cancel() { lock.lock(); canceled = true; let task = task; lock.unlock(); task?.cancel() }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) } }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw SortError.message("Speech model server rejected the download.") }
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) { if let error { finish(.failure(error)) } }
    private func finish(_ result: Result<URL, any Error>) {
        lock.lock(); let continuation = continuation; self.continuation = nil; let session = session; self.session = nil; lock.unlock()
        continuation?.resume(with: result); session?.finishTasksAndInvalidate()
    }
}

public actor LocalTranscription {
    private var library: WhisperLibrary?
    private var modelURL: URL?
    public init() {}
    public func unload() { library = nil; modelURL = nil }
    public func transcribe(_ chunks: [AudioChunk], model: URL, language: String, draft: @escaping @Sendable (String) -> Void) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        guard let first = chunks.first else { return [] }
        if modelURL != model {
            guard let known = SpeechModel.choices.first(where: { model.lastPathComponent == "ggml-\($0.id).bin" }), try LocalFileOperations().digest(model) == known.sha256 else { throw SortError.message("Speech model failed verification. Download it again.") }
            library = try WhisperLibrary(model: model); modelURL = model
        }
        guard let library else { throw SortError.message("Speech model could not be loaded.") }
        let samples = try Self.samples(chunks)
        guard samples.count >= 8000 else { return [] }
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
        guard rms > 0.002 else { return [] }
        let receiver = DraftReceiver(draft)
        let state = Unmanaged.passRetained(receiver).toOpaque()
        defer { Unmanaged<DraftReceiver>.fromOpaque(state).release() }
        let code = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return language.withCString { language in samples.withUnsafeBufferPointer { buffer in
                library.run(library.context, buffer.baseAddress, Int32(samples.count), language, { _, _, text, user in
                    guard let text, let user else { return }
                    Unmanaged<DraftReceiver>.fromOpaque(user).takeUnretainedValue().send(String(cString: text))
                }, state)
            } }
        } onCancel: { library.cancel(library.context) }
        try Task.checkCancellation()
        guard code == 0 else { throw SortError.message("Local transcription failed. The recording is safe; retry with the Base model.") }
        return (0..<library.count(library.context)).compactMap { index in
            guard library.silence(library.context, index) < 0.75, let pointer = library.text(library.context, index) else { return nil }
            let text = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("[BLANK_AUDIO]"), !text.hasPrefix("[ Silence") else { return nil }
            return TranscriptSegment(start: first.start + library.start(library.context, index), end: first.start + library.end(library.context, index), text: text, source: first.source)
        }
    }
    private static func samples(_ chunks: [AudioChunk]) throws -> [Float] {
        var result: [Float] = []
        let output = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let origin = chunks.first?.start ?? 0
        for chunk in chunks {
            try Task.checkCancellation()
            let offset = Int(max(0, chunk.start - origin) * 16000)
            guard offset <= 16000 * 35 else { throw SortError.message("Audio has a gap beyond the transcription window. Retry the affected recording.") }
            if offset > result.count { result.append(contentsOf: repeatElement(Float(0), count: offset - result.count)) }
            let file = try AVAudioFile(forReading: chunk.url)
            guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192), let converter = AVAudioConverter(from: file.processingFormat, to: output),
                  let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 16384) else { throw SortError.message("Cannot decode recorded audio.") }
            while file.framePosition < file.length {
                try Task.checkCancellation(); try file.read(into: input)
                var supplied = false, error: NSError?
                let status = converter.convert(to: converted, error: &error) { _, state in
                    if supplied { state.pointee = .noDataNow; return nil }
                    supplied = true; state.pointee = .haveData; return input
                }
                guard status != .error else { throw error ?? SortError.message("Audio normalization failed.") }
                if let channel = converted.floatChannelData?[0] { result.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))) }
                guard result.count <= 16_000 * 35 else { throw SortError.message("Transcription windows must be shorter than 35 seconds.") }
            }
        }
        return result
    }
}
private final class DraftReceiver: @unchecked Sendable {
    let callback: @Sendable (String) -> Void
    init(_ callback: @escaping @Sendable (String) -> Void) { self.callback = callback }
    func send(_ text: String) { callback(text) }
}
private final class WhisperLibrary: @unchecked Sendable {
    typealias Draft = @convention(c) (Double, Double, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
    typealias Run = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<Float>?, Int32, UnsafePointer<CChar>?, Draft?, UnsafeMutableRawPointer?) -> Int32
    let handle: UnsafeMutableRawPointer, context: UnsafeMutableRawPointer
    let run: Run
    let cancel: @convention(c) (UnsafeMutableRawPointer?) -> Void
    let close: @convention(c) (UnsafeMutableRawPointer?) -> Void
    let count: @convention(c) (UnsafeMutableRawPointer?) -> Int32
    let text: @convention(c) (UnsafeMutableRawPointer?, Int32) -> UnsafePointer<CChar>?
    let start: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Double
    let end: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Double
    let silence: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Float
    init(model: URL) throws {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libSMMWhisper.dylib")
        guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else { throw SortError.message("Local speech engine is missing. Use the packaged app built with scripts/build.sh.") }
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T { guard let address = dlsym(handle, name) else { throw SortError.message("Speech bridge is incompatible.") }; return unsafeBitCast(address, to: type) }
        do {
            let open = try symbol("smm_whisper_open", (@convention(c) (UnsafePointer<CChar>?, Int32) -> UnsafeMutableRawPointer?).self)
            guard let context = model.path.withCString({ open($0, 1) ?? open($0, 0) }) else { throw SortError.message("Could not load the local speech model.") }
            self.handle = handle; self.context = context
            run = try symbol("smm_whisper_run", Run.self)
            cancel = try symbol("smm_whisper_cancel", (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)
            close = try symbol("smm_whisper_close", (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)
            count = try symbol("smm_whisper_count", (@convention(c) (UnsafeMutableRawPointer?) -> Int32).self)
            text = try symbol("smm_whisper_text", (@convention(c) (UnsafeMutableRawPointer?, Int32) -> UnsafePointer<CChar>?).self)
            start = try symbol("smm_whisper_start", (@convention(c) (UnsafeMutableRawPointer?, Int32) -> Double).self)
            end = try symbol("smm_whisper_end", (@convention(c) (UnsafeMutableRawPointer?, Int32) -> Double).self)
            silence = try symbol("smm_whisper_silence", (@convention(c) (UnsafeMutableRawPointer?, Int32) -> Float).self)
        } catch { dlclose(handle); throw error }
    }
    deinit { close(context); dlclose(handle) }
}
