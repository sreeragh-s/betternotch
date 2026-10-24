import Foundation
import Darwin
import Testing
@testable import BetterNotchCore

private final class ReplySocketFixture: @unchecked Sendable {
    let root: URL
    let url: URL
    let thread = UUID().uuidString
    let fd: Int32
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("smm-reply-" + UUID().uuidString.prefix(8))
        url = root.appendingPathComponent("ipc.sock")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(url.path.utf8) + [0]) }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard fd >= 0, result == 0, listen(fd, 1) == 0 else { throw CodexReplyError.unavailable }
    }
    deinit { close(fd); try? FileManager.default.removeItem(at: root) }
    func serve(active: Bool) throws -> [String] {
        let peer = accept(fd, nil, nil)
        guard peer >= 0 else { throw CodexReplyError.unavailable }
        defer { close(peer) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0), one: Int32 = 1
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        func read(_ count: Int) throws -> Data {
            var data = Data()
            while data.count < count {
                var bytes = [UInt8](repeating: 0, count: count - data.count)
                let size = recv(peer, &bytes, bytes.count, 0)
                guard size > 0 else { throw CodexReplyError.unavailable }; data.append(contentsOf: bytes.prefix(size))
            }
            return data
        }
        func send(_ value: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: value)
            var size = UInt32(data.count).littleEndian
            var frame = withUnsafeBytes(of: &size) { Data($0) }; frame.append(data)
            try frame.withUnsafeBytes { bytes in
                var sent = 0
                while sent < bytes.count {
                    let count = Darwin.send(peer, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                    guard count > 0 else { throw CodexReplyError.unavailable }; sent += count
                }
            }
        }
        var methods: [String] = []
        while true {
            let bytes = Array(try read(4)), size = Int(UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24)
            guard size < 262_144, let value = try JSONSerialization.jsonObject(with: read(size)) as? [String: Any], let method = value["method"] as? String else { throw CodexReplyError.incompatible }
            let params = value["params"] as? [String: Any] ?? [:]
            if value["type"] as? String == "broadcast" {
                if params["following"] as? Bool == false { return methods }
                #expect(params["conversationId"] as? String == thread)
                #expect(value["targetClientIds"] as? [String] == ["owner-fixture"])
                let state: [String: Any] = ["id": thread, "hostId": "local", "cwd": "/tmp/project", "threadRuntimeStatus": ["type": active ? "active" : "idle"], "turns": [["items": [["id": "call-socket", "type": "agentMessage", "questions": [["title": "Which output?"]]]]]]]
                try send(["type": "broadcast", "sourceClientId": "owner-fixture", "method": "thread-stream-state-changed", "params": ["conversationId": thread, "change": ["type": "snapshot", "conversationState": state]]])
                continue
            }
            methods.append(method)
            var result: [String: Any] = [:]
            switch method {
            case "initialize": result = ["clientId": "client-fixture"]
            case "thread-owner-discovery": #expect(params["conversationId"] as? String == thread)
            case "thread-follower-steer-turn", "thread-follower-start-turn":
                #expect(value["targetClientId"] as? String == "owner-fixture")
                #expect(params["conversationId"] as? String == thread)
                let turnStart = params["turnStart"] as? [String: Any], request = turnStart?["request"] as? [String: Any]
                let input = (params["input"] ?? request?["input"]) as? [[String: Any]]
                let text = input?.first?["text"] as? String ?? ""
                #expect(text.contains("call-socket")); #expect(text.contains("PNG")); #expect(text.contains("<send_user_message_question_reply>"))
                #expect(request?["approvalPolicy"] == nil); #expect(request?["model"] == nil)
                result = ["result": ["turnId": "fixture-turn"]]
            default: throw CodexReplyError.incompatible
            }
            try send(["type": "response", "requestId": value["requestId"]!, "resultType": "success", "method": method, "handledByClientId": "owner-fixture", "result": result])
        }
    }
}

@Test(arguments: [true, false]) func desktopReplyUsesBoundedLocalProtocolForActiveAndIdleChats(active: Bool) async throws {
    let fixture = try ReplySocketFixture()
    let server = Task.detached { try fixture.serve(active: active) }
    let questions = try JSONDecoder().decode([CodexQuestion].self, from: Data(#"[{"id":"q","question":"Which output?"}]"#.utf8))
    let event = CodexEvent(kind: .question, threadID: fixture.thread, title: "Question", questions: questions, questionCallID: "call-socket")
    try await CodexDesktopReply(socketURL: fixture.url).submit(event: event, answers: ["q": "PNG"])
    let methods = try await server.value
    #expect(methods == ["initialize", "thread-owner-discovery", active ? "thread-follower-steer-turn" : "thread-follower-start-turn"])
}
