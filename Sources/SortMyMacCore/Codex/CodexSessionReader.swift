import Foundation
import CryptoKit
import Darwin

/// A version-tolerant, read-only adapter for *new* desktop question events. This is not an approval channel.
public struct CodexSessionDecoder: Sendable {
    public var threadID: String
    public var project = ""
    public var turnID = ""
    private var pending: [String: UUID] = [:]
    private var remaining: [String: Set<Int>] = [:]
    public init(threadID: String) { self.threadID = threadID }
    private func identifier(_ call: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data((threadID + ":" + call).utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    public mutating func decode(_ data: Data, now: Date = Date()) -> [CodexEvent] {
        guard data.count <= CodexBridgeStore.maximumBytes,
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = record["type"] as? String, let payload = record["payload"] as? [String: Any] else { return [] }
        if kind == "session_meta" {
            if let id = payload["id"] as? String, UUID(uuidString: id) != nil { threadID = id }
            project = payload["cwd"] as? String ?? project; return []
        }
        if kind == "turn_context" { turnID = payload["turn_id"] as? String ?? turnID; project = payload["cwd"] as? String ?? project; return [] }
        guard kind == "response_item" else { return [] }
        let type = payload["type"] as? String
        if type == "function_call", let name = payload["name"] as? String,
           name.split(separator: ".").last.map(String.init)?.hasPrefix("request_user_input") == true,
           let call = payload["call_id"] as? String, !call.isEmpty,
           let arguments = payload["arguments"] as? String, arguments.utf8.count <= CodexBridgeStore.maximumBytes,
           let args = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] {
            let hook: [String: Any] = ["hook_event_name": "PreToolUse", "session_id": threadID, "turn_id": turnID, "cwd": project, "tool_name": name, "tool_input": args]
            guard let value = try? JSONSerialization.data(withJSONObject: hook), let event = try? CodexEvent.hook(value, now: now, eventID: identifier(call), questionCallID: name.hasSuffix("request_user_input_async") ? call : nil) else { return [] }
            pending[call] = event.id
            remaining[call] = Set(event.questions.indices)
            if pending.count > 64, let key = pending.keys.first { pending.removeValue(forKey: key); remaining.removeValue(forKey: key) }
            return [event]
        }
        if type == "function_call_output", let call = payload["call_id"] as? String, pending[call] != nil,
           let raw = payload["output"] as? String,
           let output = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any], output["answers"] != nil {
            return resolve(call, now: now)
        }
        // Async questions return {accepted:true} immediately. Only an actual user reply resolves them.
        if type == "message", payload["role"] as? String == "user", let content = payload["content"] as? [[String: Any]] {
            var result: [CodexEvent] = []
            for item in content {
                guard let text = item["text"] as? String,
                      let start = text.range(of: "<send_user_message_question_reply>"),
                      let end = text.range(of: "</send_user_message_question_reply>", range: start.upperBound..<text.endIndex),
                      let replies = try? JSONSerialization.jsonObject(with: Data(text[start.upperBound..<end.lowerBound].utf8)) as? [[String: Any]] else { continue }
                for reply in replies {
                    guard let rawID = reply["questionItemId"] as? String,
                          let parts = try? JSONSerialization.jsonObject(with: Data(rawID.utf8)) as? [Any] else { continue }
                    for call in Array(pending.keys) where parts.contains(where: { $0 as? String == call }) {
                        guard let index = parts.last as? Int else { continue }
                        remaining[call]?.remove(index)
                        if remaining[call]?.isEmpty == true { result += resolve(call, now: now) }
                    }
                }
            }
            return result
        }
        return []
    }
    private mutating func resolve(_ call: String, now: Date) -> [CodexEvent] {
        guard let id = pending.removeValue(forKey: call) else { return [] }
        remaining.removeValue(forKey: call)
        return [CodexEvent(createdAt: now, kind: .resolved, threadID: threadID, turnID: turnID, title: "Answered in Codex", resolvesID: id, resolution: "Answered in Codex")]
    }
}

public struct CodexSessionLines: Sendable {
    private var buffer = Data()
    private var skipping = false
    public init() { }
    public mutating func discardCurrentLine() { buffer.removeAll(keepingCapacity: true); skipping = true }
    public mutating func append(_ bytes: Data) -> [Data] {
        var lines: [Data] = []
        for byte in bytes {
            if byte == 10 {
                if !skipping && !buffer.isEmpty { lines.append(buffer) }
                buffer.removeAll(keepingCapacity: true); skipping = false
            } else if !skipping {
                if buffer.count < CodexBridgeStore.maximumBytes { buffer.append(byte) }
                else { buffer.removeAll(keepingCapacity: true); skipping = true }
            }
        }
        return lines
    }
}

public actor CodexSessionReader {
    private struct Cursor {
        var offset: UInt64
        var identity: UInt64
        var decoder: CodexSessionDecoder
        var lines = CodexSessionLines()
    }
    private let root: URL
    private var cursors: [URL: Cursor] = [:]
    private var knownFiles: Set<URL>?
    public init(root: URL) { self.root = root }
    public static var standardRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions") }

    /// Files are sought to EOF on discovery; existing conversations are never backfilled.
    public func poll(now: Date = Date()) -> [CodexEvent] {
        var files: [(URL, Date)] = []
        var allFiles = Set<URL>()
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        for day in 0..<3 {
            let date = Calendar.current.date(byAdding: .day, value: -day, to: now) ?? now
            let folder = root.appendingPathComponent(formatter.string(from: date))
            for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
                allFiles.insert(url)
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]), let modified = values.contentModificationDate,
                      now.timeIntervalSince(modified) < 3600 else { continue }
                files.append((url, modified))
            }
        }
        let watched = files.sorted { $0.1 > $1.1 }.prefix(16).map(\.0)
        let previouslyKnown = knownFiles
        knownFiles = allFiles
        cursors = cursors.filter { watched.contains($0.key) }
        var result: [CodexEvent] = []
        var budget = 2_097_152
        for url in watched {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { continue }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else { continue }
            let size = UInt64(info.st_size)
            if cursors[url] == nil || cursors[url]?.identity != UInt64(info.st_ino) || (cursors[url]?.offset ?? 0) > size {
                let stem = url.deletingPathExtension().lastPathComponent
                let id = String(stem.suffix(36))
                guard UUID(uuidString: id) != nil else { continue }
                var decoder = CodexSessionDecoder(threadID: id)
                // Only hydrate session identity/cwd, never old conversation events or instructions.
                if let head = try? handle.read(upToCount: 65_536), let end = head.firstIndex(of: 10) { _ = decoder.decode(Data(head[..<end]), now: now) }
                let isNewSession = previouslyKnown != nil && previouslyKnown?.contains(url) == false
                var cursor = Cursor(offset: isNewSession ? 0 : size, identity: UInt64(info.st_ino), decoder: decoder)
                // If discovery caught an in-progress line, discard its remainder rather than parsing a suffix.
                if !isNewSession && size > 0 { try? handle.seek(toOffset: size - 1); if (try? handle.read(upToCount: 1)) != Data([10]) { cursor.lines.discardCurrentLine() } }
                cursors[url] = cursor; continue
            }
            guard budget > 0, var cursor = cursors[url], size > cursor.offset else { continue }
            do {
                try handle.seek(toOffset: cursor.offset)
                let count = min(524_288, budget)
                guard let bytes = try handle.read(upToCount: count), !bytes.isEmpty else { continue }
                cursor.offset += UInt64(bytes.count); budget -= bytes.count
                for line in cursor.lines.append(bytes) { result += cursor.decoder.decode(line, now: now) }
                cursors[url] = cursor
            } catch { continue }
        }
        return result
    }
}
