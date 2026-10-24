import Foundation
import Testing
@testable import SortMyMacCore

private func hookData(_ name: String, tool: String = "Bash", args: [String: Any] = [:], extra: [String: Any] = [:]) throws -> Data {
    var value: [String: Any] = ["hook_event_name": name, "session_id": "thread-a", "turn_id": "turn-a", "cwd": "/tmp/project", "tool_name": tool, "tool_input": args]
    value.merge(extra) { _, new in new }
    return try JSONSerialization.data(withJSONObject: value)
}
private func inbox() throws -> CodexBridgeStore {
    let store = CodexBridgeStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("SortMyMac-Codex-Test-" + UUID().uuidString))
    try store.prepare(); return store
}

@Test func codexApprovalIsBoundToAnExpiringSingleRequest() throws {
    let now = Date()
    let event = try #require(try CodexEvent.hook(hookData("PermissionRequest", args: ["command": "swift test", "description": "Run project checks", "additionalPermissions": ["network": true]]), now: now))
    #expect(event.kind == .approval); #expect(event.command == "swift test")
    #expect(event.message.contains("additionalPermissions")); #expect(event.isPending(at: now.addingTimeInterval(89)))
    #expect(!event.isPending(at: now.addingTimeInterval(91)))
    let reply = CodexDecision(event: event, choice: .allow)
    #expect(reply.matches(event, now: now))
    #expect(!reply.matches(CodexEvent(kind: .approval, threadID: event.threadID, title: "Another request", expiresAt: event.expiresAt), now: now))
    #expect(!reply.matches(event, now: now.addingTimeInterval(91)))
    let responseData = try #require(try reply.hookOutput())
    let object = try #require(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    let output = try #require(object["hookSpecificOutput"] as? [String: Any])
    #expect((output["decision"] as? [String: String]) == ["behavior": "allow"])
    #expect(try CodexDecision(event: event, choice: .codex).hookOutput() == nil)
}

@Test func codexQuestionsPreserveChoicesAndSupportAsyncQuestionShape() throws {
    let event = try #require(try CodexEvent.hook(hookData("PreToolUse", tool: "request_user_input", args: ["questions": [["id": "format", "header": "Format", "question": "Which format?", "options": [["label": "PNG", "description": "Preserve transparency"], ["label": "JPEG", "description": "Smaller output"]]]]])))
    #expect(event.kind == .question); #expect(event.questions.first?.options?.first?.description == "Preserve transparency")
    #expect(!event.isPending()); #expect(CodexDecision(event: event, choice: .allow).matches(event) == false)
    let asyncEvent = try #require(try CodexEvent.hook(hookData("PreToolUse", tool: "request_user_input_async", args: ["questions": [["title": "Which size?", "options": ["Small", "Large"]]]])))
    #expect(asyncEvent.questions.first?.question == "Which size?"); #expect(asyncEvent.questions.first?.options?.last?.label == "Large")
    #expect(try CodexEvent.hook(hookData("PostToolUse", tool: "request_user_input"))?.kind == .answered)
}

@Test func codexParserIgnoresUnrelatedToolsAndBoundsPreviews() throws {
    #expect(try CodexEvent.hook(hookData("PreToolUse", args: ["command": "echo hello"])) == nil)
    #expect(try CodexEvent.hook(hookData("Unknown")) == nil)
    let event = try #require(try CodexEvent.hook(hookData("PreToolUse", tool: "apply_patch", args: ["command": String(repeating: "+added\n", count: 6000)])))
    #expect(event.kind == .changes); #expect(event.diff.contains("Preview truncated")); #expect(event.diff.count < 24_200)
    #expect(try CodexEvent.hook(hookData("Stop", extra: ["last_assistant_message": "Checks passed"]))?.message == "Checks passed")
}

@Test func codexMailboxRejectsStaleApprovalsAndSymlinks() throws {
    let store = try inbox(); defer { try? FileManager.default.removeItem(at: store.root) }
    let now = Date()
    let event = CodexEvent(createdAt: now, kind: .approval, threadID: "a", title: "Test", expiresAt: now.addingTimeInterval(90))
    #expect(!store.isAvailable(now: now))
    #expect(throws: (any Error).self) { try store.respond(CodexDecision(event: event, choice: .allow), to: event, now: now) }
    try store.heartbeat(now: now)
    try store.respond(CodexDecision(event: event, choice: .deny), to: event, now: now)
    #expect(store.decision(for: event, now: now)?.choice == .deny)
    #expect(store.decision(for: event, now: now.addingTimeInterval(100)) == nil)
    try store.publish(event)
    #expect(try store.consume(now: now) == [event]); #expect(try store.consume(now: now).isEmpty)
    let fake = CodexEvent(kind: .completed, threadID: "a", title: "Untrusted link")
    let source = store.root.appendingPathComponent("outside.json")
    try JSONEncoder().encode(fake).write(to: source)
    try FileManager.default.createSymbolicLink(at: store.root.appendingPathComponent(fake.id.uuidString + ".event"), withDestinationURL: source)
    #expect(try store.consume().isEmpty)
    store.stop(); #expect(!store.isAvailable())
}

@Test func codexHookInstallationPreservesUnrelatedHandlersAndIsIdempotent() throws {
    let store = try inbox(); defer { try? FileManager.default.removeItem(at: store.root) }
    let hooks = store.root.appendingPathComponent("hooks.json")
    let original = Data(#"{"description":"Existing hooks","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo keep-me"}]}]}}"#.utf8)
    try original.write(to: hooks)
    let helper = URL(fileURLWithPath: "/tmp/it has a 'quote/SortMyMacCodexBridge")
    try CodexHookInstaller.update(at: hooks, helper: helper, inbox: store.root, install: true)
    let first = try Data(contentsOf: hooks)
    try CodexHookInstaller.update(at: hooks, helper: helper, inbox: store.root, install: true)
    #expect(try Data(contentsOf: hooks) == first)
    #expect(CodexHookInstaller.isInstalled(at: hooks))
    #expect(String(data: first, encoding: .utf8)?.contains("echo keep-me") == true)
    try CodexHookInstaller.update(at: hooks, helper: helper, inbox: store.root, install: false)
    #expect(!CodexHookInstaller.isInstalled(at: hooks))
    #expect(String(data: try Data(contentsOf: hooks), encoding: .utf8)?.contains("echo keep-me") == true)
    let backups = try FileManager.default.contentsOfDirectory(at: store.root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("sortmymac-backup") }
    #expect(backups.count == 3); #expect(try backups.contains { try Data(contentsOf: $0) == original })
}

@Test func codexInstallerDoesNotOverwriteMalformedConfig() throws {
    let store = try inbox(); defer { try? FileManager.default.removeItem(at: store.root) }
    let hooks = store.root.appendingPathComponent("hooks.json"), original = Data("not-json".utf8)
    try original.write(to: hooks)
    #expect(throws: (any Error).self) { try CodexHookInstaller.update(at: hooks, helper: hooks, inbox: store.root, install: true) }
    #expect(try Data(contentsOf: hooks) == original)
}
