import Foundation

public struct CodexQuestion: Codable, Equatable, Sendable, Identifiable {
    public struct Option: Codable, Equatable, Sendable {
        public let label: String
        public let description: String?
    }
    public let id: String
    public let header: String?
    public let question: String
    public let options: [Option]?
    public let isSecret: Bool?
}

public struct CodexEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case working, completed, interrupted, approval, question, answered, changes, resolved }
    public let id: UUID
    public let createdAt: Date
    public let kind: Kind
    public let threadID: String
    public let turnID: String
    public let project: String
    public let title: String
    public let message: String
    public let command: String
    public let diff: String
    public let questions: [CodexQuestion]
    public let expiresAt: Date?
    public let resolvesID: UUID?
    public let resolution: String?
    public let questionCallID: String?
    public var needsAttention: Bool { kind == .approval || kind == .question }
    public func isPending(at date: Date = Date()) -> Bool { kind == .approval && (expiresAt ?? .distantPast) > date }

    public init(id: UUID = UUID(), createdAt: Date = Date(), kind: Kind, threadID: String, turnID: String = "", project: String = "", title: String, message: String = "", command: String = "", diff: String = "", questions: [CodexQuestion] = [], expiresAt: Date? = nil, resolvesID: UUID? = nil, resolution: String? = nil, questionCallID: String? = nil) {
        self.id = id; self.createdAt = createdAt; self.kind = kind; self.threadID = threadID; self.turnID = turnID; self.project = project
        self.title = title; self.message = message; self.command = command; self.diff = diff; self.questions = questions
        self.expiresAt = expiresAt; self.resolvesID = resolvesID; self.resolution = resolution
        self.questionCallID = questionCallID
    }

    /// Interpret only the documented hook fields. Never read authentication or session-history files.
    public static func hook(_ data: Data, now: Date = Date(), eventID: UUID = UUID(), questionCallID: String? = nil) throws -> Self? {
        guard data.count <= CodexBridgeStore.maximumBytes,
              let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = input["hook_event_name"] as? String,
              let thread = input["session_id"] as? String, !thread.isEmpty else { return nil }
        let tool = input["tool_name"] as? String ?? ""
        let args = input["tool_input"] as? [String: Any] ?? [:]
        let command = args["command"] as? String ?? args["cmd"] as? String ?? ""
        let patch = tool.lowercased().contains("apply_patch") || tool == "Edit" || tool == "Write"
        let turn = input["turn_id"] as? String ?? ""
        let project = input["cwd"] as? String ?? ""
        func limited(_ text: String, _ count: Int = 24_000) -> String {
            text.count > count ? String(text.prefix(count)) + "\n… Preview truncated. Open Codex for the full content." : text
        }
        func event(_ kind: Kind, _ title: String, message: String = "", questions: [CodexQuestion] = [], approval: Bool = false) -> Self {
            Self(id: eventID, createdAt: now, kind: kind, threadID: thread, turnID: turn, project: project, title: title, message: limited(message),
                 command: patch ? "" : limited(command), diff: patch ? limited(command) : "", questions: questions, expiresAt: approval ? now.addingTimeInterval(90) : nil, questionCallID: kind == .question ? questionCallID : nil)
        }
        switch name {
        case "PermissionRequest":
            // Decisions are restricted to this one request; never persist an allow policy.
            let description = args["description"] as? String ?? args["justification"] as? String ?? ""
            let detail = description.isEmpty ? "Review this request in Codex if its scope is unclear." : description
            let details = args.filter { !["command", "cmd", "description", "justification"].contains($0.key) }
            let preview = !details.isEmpty ? limited(String(data: try JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8) ?? "") : ""
            return event(.approval, "Allow \(tool.isEmpty ? "this action" : tool)?", message: detail + (preview.isEmpty ? "" : "\n\n" + preview), approval: true)
        case "PreToolUse":
            if tool.lowercased().contains("request_user_input"), let raw = args["questions"] as? [[String: Any]] {
                let normalized: [[String: Any]] = raw.enumerated().map { index, question in
                    var result = question
                    result["id"] = question["id"] as? String ?? "question-\(index)"
                    result["question"] = question["question"] as? String ?? question["title"] as? String ?? "Question"
                    if let options = question["options"] as? [String] { result["options"] = options.map { ["label": $0] } }
                    return result
                }
                let questions = try JSONDecoder().decode([CodexQuestion].self, from: JSONSerialization.data(withJSONObject: normalized))
                guard !questions.isEmpty, questions.count <= 3 else { return nil }
                return event(.question, "Codex has a question", questions: questions)
            }
            if patch { return event(.changes, "Proposed file changes") }
            return nil
        case "PostToolUse":
            if tool.lowercased().contains("request_user_input") { return event(.answered, "Question answered in Codex") }
            return patch ? event(.changes, "File change activity", message: "Check Codex for the final execution result.") : nil
        case "UserPromptSubmit": return event(.working, "Codex is working")
        case "Stop": return event(.completed, "Codex finished", message: input["last_assistant_message"] as? String ?? "Open the chat to review the result.")
        case "Interrupt", "SessionEnd": return event(.interrupted, "Codex stopped")
        default: return nil
        }
    }
}

public struct CodexDecision: Codable, Sendable, Equatable {
    public enum Choice: String, Codable, Sendable { case allow, deny, codex }
    public let eventID: UUID
    public let threadID: String
    public let turnID: String
    public let choice: Choice
    public init(event: CodexEvent, choice: Choice) { eventID = event.id; threadID = event.threadID; turnID = event.turnID; self.choice = choice }
    public func matches(_ event: CodexEvent, now: Date = Date()) -> Bool {
        eventID == event.id && threadID == event.threadID && turnID == event.turnID && event.isPending(at: now)
    }
    public func hookOutput() throws -> Data? {
        guard choice != .codex else { return nil }
        var decision = ["behavior": choice == .allow ? "allow" : "deny"]
        if choice == .deny { decision["message"] = "Declined by the user in BetterNotch." }
        return try JSONSerialization.data(withJSONObject: ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]], options: [.sortedKeys])
    }
}
