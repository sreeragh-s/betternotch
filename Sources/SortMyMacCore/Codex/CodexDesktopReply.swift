import Foundation
import Darwin

public enum CodexReplyError: Error, LocalizedError, Sendable {
    case unavailable, incompatible, stale, invalidAnswer, unconfirmed
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Codex’s local reply connection is unavailable. Open this question in Codex."
        case .incompatible: "This Codex version uses a different reply format. Open the question in Codex."
        case .stale: "This question is no longer available in the target Codex chat."
        case .invalidAnswer: "Choose or enter an answer for every question. Private answers must be entered in Codex."
        case .unconfirmed: "Delivery could not be confirmed. Check Codex before sending again."
        }
    }
}

/// Version-specific desktop adapter. It never changes approval policy or writes to Codex's session files.
public struct CodexDesktopReply: Sendable {
    public let socketURL: URL
    public init(socketURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/ipc/ipc.sock")) { self.socketURL = socketURL }
    public func submit(event: CodexEvent, answers: [String: String]) async throws {
        let url = socketURL
        try await Task.detached {
            guard event.kind == .question, UUID(uuidString: event.threadID) != nil, let call = event.questionCallID, !call.isEmpty,
                  !event.questions.isEmpty, event.questions.count <= 3,
                  event.questions.allSatisfy({ $0.isSecret != true && !(answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  answers.values.allSatisfy({ $0.utf8.count <= 32_000 }) else { throw CodexReplyError.invalidAnswer }
            let connection = try DesktopSocket(url: url)
            try connection.initialize()
            let ownerReply = try connection.request("thread-owner-discovery", version: 1, params: ["hostId": "local", "conversationId": event.threadID])
            guard let owner = ownerReply["handledByClientId"] as? String else { throw CodexReplyError.unavailable }
            try connection.follow(thread: event.threadID, owner: owner, following: true)
            defer { try? connection.follow(thread: event.threadID, owner: owner, following: false) }
            let state = try connection.snapshot(thread: event.threadID, owner: owner)
            let text = try Self.validatedReply(event: event, answers: answers, state: state)
            let messageID = UUID().uuidString
            let input: [[String: Any]] = [["type": "text", "text": text, "text_elements": []]]
            let cwd = state["cwd"] as? String ?? event.project
            let restore: [String: Any] = ["id": messageID, "text": text, "cwd": cwd, "createdAt": Date().timeIntervalSince1970 * 1000,
                "context": ["prompt": text, "addedFiles": [], "fileAttachments": [], "ideContext": NSNull(), "imageAttachments": [], "workspaceRoots": [cwd]]]
            let status = (state["threadRuntimeStatus"] as? [String: Any])?["type"] as? String
            let active = status == "active"
            var dispatched = false
            do {
                if active {
                    dispatched = true
                    let reply = try connection.request("thread-follower-steer-turn", version: 1, params: ["conversationId": event.threadID, "input": input, "restoreMessage": restore, "clientUserMessageId": messageID, "attachments": []], owner: owner, allowError: true)
                    if reply["resultType"] as? String != "success" {
                        // This exact pre-dispatch error is the only safe automatic fallback. Never retry an ambiguous send.
                        guard reply["error"] as? String == "Cannot steer conversation \(event.threadID) because its active turn already ended" else { throw CodexReplyError.unconfirmed }
                        try connection.start(thread: event.threadID, owner: owner, input: input, restore: restore, messageID: messageID)
                    }
                } else {
                    dispatched = true
                    try connection.start(thread: event.threadID, owner: owner, input: input, restore: restore, messageID: messageID)
                }
            } catch { throw dispatched ? CodexReplyError.unconfirmed : error }
        }.value
    }

    /// Validate the exact chat, native question identity, text, and unresolved indices before constructing a reply.
    public static func validatedReply(event: CodexEvent, answers: [String: String], state: [String: Any]) throws -> String {
        guard state["id"] as? String == event.threadID, state["hostId"] as? String == "local", let call = event.questionCallID else { throw CodexReplyError.stale }
        var turns = state["turns"] as? [[String: Any]] ?? []
        if let history = (state["turnHistory"] as? [String: Any])?["history"] as? [String: Any], let entities = history["entitiesByKey"] as? [String: Any] { turns += entities.values.compactMap { $0 as? [String: Any] } }
        let items = turns.flatMap { $0["items"] as? [[String: Any]] ?? [] }
        guard let original = items.first(where: { $0["type"] as? String == "agentMessage" && $0["id"] as? String == call }),
              let questions = original["questions"] as? [[String: Any]], questions.count == event.questions.count else { throw CodexReplyError.stale }
        var answered = Set<Int>()
        for item in items {
            let type = item["type"] as? String
            guard type == "userMessage" || (type == "steeringUserMessage" && item["status"] as? String == "accepted") else { continue }
            let content = (item["content"] ?? item["input"]) as? [[String: Any]] ?? []
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            guard let begin = text.range(of: "<send_user_message_question_reply>"), let end = text.range(of: "</send_user_message_question_reply>", range: begin.upperBound..<text.endIndex),
                  let replies = try? JSONSerialization.jsonObject(with: Data(text[begin.upperBound..<end.lowerBound].utf8)) as? [[String: Any]] else { continue }
            for reply in replies {
                guard let id = reply["questionItemId"] as? String, let parts = try? JSONSerialization.jsonObject(with: Data(id.utf8)) as? [Any], parts.count == 3, parts[1] as? String == call, let index = parts[2] as? Int else { continue }
                answered.insert(index)
            }
        }
        var replies: [[String: String]] = []
        for (index, question) in event.questions.enumerated() {
            let native = questions[index]
            guard (native["question"] as? String ?? native["title"] as? String) == question.question else { throw CodexReplyError.stale }
            guard native["isSecret"] as? Bool != true, question.isSecret != true else { throw CodexReplyError.invalidAnswer }
            if answered.contains(index) { continue }
            guard let answer = answers[question.id], !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, answer.utf8.count <= 32_000 else { throw CodexReplyError.invalidAnswer }
            let id = try JSONSerialization.data(withJSONObject: ["request_user_input_async", call, index])
            replies.append(["questionItemId": String(decoding: id, as: UTF8.self), "question": question.question, "answer": answer])
        }
        guard !replies.isEmpty else { throw CodexReplyError.stale }
        let body = String(decoding: try JSONSerialization.data(withJSONObject: replies, options: [.sortedKeys]), as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e")
        return "<send_user_message_question_reply>\n" + body + "\n</send_user_message_question_reply>"
    }
}

private final class DesktopSocket {
    private var fd: Int32
    private let deadline = Date().addingTimeInterval(10)
    private var client = "sortmymac"
    init(url: URL) throws {
        for path in [url.deletingLastPathComponent().path, url.path] {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw CodexReplyError.unavailable }
            if path == url.path { guard info.st_mode & S_IFMT == S_IFSOCK else { throw CodexReplyError.unavailable } }
            else { guard info.st_mode & S_IFMT == S_IFDIR else { throw CodexReplyError.unavailable } }
        }
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw CodexReplyError.unavailable }
        fd = socketFD
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(url.path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { fd = -1; close(socketFD); throw CodexReplyError.unavailable }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if connected != 0 && errno != EINPROGRESS { fd = -1; close(socketFD); throw CodexReplyError.unavailable }
        if connected != 0 {
            do { try wait(POLLOUT) } catch { fd = -1; close(socketFD); throw error }
            var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { fd = -1; close(socketFD); throw CodexReplyError.unavailable }
        }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { fd = -1; close(socketFD); throw CodexReplyError.unavailable }
    }
    deinit { if fd >= 0 { close(fd) } }
    private func wait(_ event: Int32) throws {
        let flag = Int16(event)
        var descriptor = pollfd(fd: fd, events: flag, revents: 0)
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0, Darwin.poll(&descriptor, 1, Int32(remaining * 1000)) > 0, descriptor.revents & flag != 0 else { throw CodexReplyError.unavailable }
    }
    private func read(_ count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            try wait(POLLIN)
            var buffer = [UInt8](repeating: 0, count: min(65_536, count - result.count))
            let size = recv(fd, &buffer, buffer.count, 0)
            if size < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard size > 0 else { throw CodexReplyError.unavailable }
            result.append(contentsOf: buffer.prefix(size))
        }
        return result
    }
    private func send(_ message: [String: Any]) throws {
        let body = try JSONSerialization.data(withJSONObject: message)
        guard body.count <= 262_144 else { throw CodexReplyError.invalidAnswer }
        let size = UInt32(body.count)
        var frame = Data([UInt8(size & 255), UInt8((size >> 8) & 255), UInt8((size >> 16) & 255), UInt8((size >> 24) & 255)])
        frame.append(body)
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(POLLOUT)
                let sent = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if sent < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard sent > 0 else { throw CodexReplyError.unavailable }; offset += sent
            }
        }
    }
    private func receive() throws -> [String: Any] {
        let head = Array(try read(4))
        let size = Int(UInt32(head[0]) | UInt32(head[1]) << 8 | UInt32(head[2]) << 16 | UInt32(head[3]) << 24)
        guard size > 0, size <= 16_777_216 else { throw CodexReplyError.incompatible }
        guard let message = try JSONSerialization.jsonObject(with: read(size)) as? [String: Any] else { throw CodexReplyError.incompatible }
        if message["type"] as? String == "client-discovery-request", let id = message["requestId"] as? String {
            try send(["type": "client-discovery-response", "requestId": id, "response": ["canHandle": false]])
        }
        return message
    }
    func initialize() throws {
        let reply = try request("initialize", version: 0, params: ["clientType": "sortmymac"])
        guard let id = (reply["result"] as? [String: Any])?["clientId"] as? String else { throw CodexReplyError.incompatible }
        client = id
    }
    func request(_ method: String, version: Int, params: [String: Any], owner: String? = nil, allowError: Bool = false) throws -> [String: Any] {
        let id = UUID().uuidString
        var message: [String: Any] = ["type": "request", "requestId": id, "sourceClientId": client, "version": version, "method": method, "params": params]
        if let owner { message["targetClientId"] = owner }
        try send(message)
        while true {
            let reply = try receive()
            if reply["type"] as? String == "response", reply["requestId"] as? String == id {
                guard allowError || reply["resultType"] as? String == "success" else { throw CodexReplyError.unavailable }
                if reply["resultType"] as? String == "success", reply["method"] as? String != method { throw CodexReplyError.incompatible }
                return reply
            }
        }
    }
    func follow(thread: String, owner: String, following: Bool) throws {
        try send(["type": "broadcast", "sourceClientId": client, "version": 1, "method": "thread-stream-following-changed", "targetClientIds": [owner], "params": ["hostId": "local", "conversationId": thread, "following": following]])
    }
    func snapshot(thread: String, owner: String) throws -> [String: Any] {
        while true {
            let message = try receive()
            guard message["method"] as? String == "thread-stream-state-changed", message["sourceClientId"] as? String == owner,
                  let params = message["params"] as? [String: Any], params["conversationId"] as? String == thread,
                  let change = params["change"] as? [String: Any], change["type"] as? String == "snapshot",
                  let state = change["conversationState"] as? [String: Any] else { continue }
            return state
        }
    }
    func start(thread: String, owner: String, input: [[String: Any]], restore: [String: Any], messageID: String) throws {
        _ = try request("thread-follower-start-turn", version: 2, params: ["conversationId": thread, "turnStart": ["request": ["threadId": thread, "input": input, "clientUserMessageId": messageID], "context": ["restoreMessage": restore]]], owner: owner)
    }
}
