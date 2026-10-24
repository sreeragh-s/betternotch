import Foundation

public enum MeetingStatus: String, Codable, Sendable { case recording, paused, finalizing, ready, interrupted, failed }
public enum AudioSource: String, Codable, CaseIterable, Sendable { case microphone, system, both }
public struct AudioChunk: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var source: AudioSource
    public var url: URL
    public var start: Double
    public var duration: Double
    public init(source: AudioSource, url: URL, start: Double, duration: Double) { self.source = source; self.url = url; self.start = start; self.duration = duration }
}
public struct TranscriptSegment: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var start: Double
    public var end: Double
    public var text: String
    public var source: AudioSource
    public var edited = false
    public init(start: Double, end: Double, text: String, source: AudioSource = .both) { self.start = start; self.end = end; self.text = text; self.source = source }
}
public struct TranscriptRevision: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var created = Date()
    public var segments: [TranscriptSegment]
    public init(segments: [TranscriptSegment]) { self.segments = segments }
}
public struct MeetingRecord: Codable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var created = Date()
    public var audioURL: URL?
    public var duration = 0.0
    public var status: MeetingStatus = .recording
    public var source: AudioSource
    public var chunks: [AudioChunk] = []
    public var segments: [TranscriptSegment] = []
    public var revisions: [TranscriptRevision] = []
    public var processedChunks: [UUID] = []
    public var transcriptStatus = "Waiting for speech model"
    public var summary = ""
    public var error: String?
    public init(id: UUID = UUID(), title: String = "", source: AudioSource = .both) {
        self.id = id; self.source = source
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Meeting — " + Date().formatted(date: .abbreviated, time: .shortened) : title
    }
    public var searchableText: String { ([title] + segments.map(\.text)).joined(separator: "\n") }
}
public enum TranscriptExporter {
    public static func text(_ meeting: MeetingRecord, format: String) -> String {
        let segments = meeting.segments.sorted { $0.start == $1.start ? $0.source.rawValue < $1.source.rawValue : $0.start < $1.start }
        switch format {
        case "srt": return segments.enumerated().map { "\($0.offset + 1)\n\(timestamp($0.element.start, comma: true)) --> \(timestamp($0.element.end, comma: true))\n\($0.element.text)\n" }.joined(separator: "\n")
        case "vtt": return "WEBVTT\n\n" + segments.map { "\(timestamp($0.start)) --> \(timestamp($0.end))\n\($0.text)\n" }.joined(separator: "\n")
        case "md": return "# \(meeting.title)\n\n" + segments.map { "**\(timestamp($0.start)) · \($0.source.rawValue)**\n\($0.text)\n" }.joined(separator: "\n")
        default: return meeting.title + "\n\n" + segments.map { "[\(timestamp($0.start))] \($0.text)" }.joined(separator: "\n")
        }
    }
    public static func seconds(_ timestamp: String) -> Double? {
        let parts = timestamp.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]), hours >= 0, minutes >= 0, minutes < 60, seconds >= 0, seconds < 60 else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
    public static func timestamp(_ seconds: Double, comma: Bool = false) -> String {
        let ms = Int(max(0, seconds) * 1000)
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, comma ? "," : ".", ms % 1000)
    }
    public static func deduplicated(_ text: String, previous: String) -> String {
        let words = text.split(separator: " ").map(String.init), tail = previous.split(separator: " ").suffix(40).map(String.init)
        for n in Swift.stride(from: min(words.count, tail.count), through: 1, by: -1) {
            if words.prefix(n).map({ $0.lowercased() }) == tail.suffix(n).map({ $0.lowercased() }) { return words.dropFirst(n).joined(separator: " ") }
        }
        return text
    }
}
