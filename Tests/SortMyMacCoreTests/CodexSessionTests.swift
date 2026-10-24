import Foundation
import Testing
@testable import SortMyMacCore

private func record(_ payload: [String: Any], kind: String = "response_item") throws -> Data {
    try JSONSerialization.data(withJSONObject: ["type": kind, "payload": payload]) + Data([10])
}
private func questionRecord(_ call: String) throws -> Data {
    let args = try JSONSerialization.data(withJSONObject: ["questions": [["title": "Which output?", "options": ["PNG", "JPEG"]]]])
    return try record(["type": "function_call", "name": "request_user_input_async", "call_id": call, "arguments": String(decoding: args, as: UTF8.self)])
}

@Test func desktopAsyncQuestionRemainsPendingUntilTheActualUserReply() throws {
    var decoder = CodexSessionDecoder(threadID: UUID().uuidString)
    let events = decoder.decode(try questionRecord("question-a"))
    let question = try #require(events.first)
    #expect(question.kind == .question); #expect(question.questions.first?.options?.last?.label == "JPEG")
    #expect(question.questionCallID == "question-a")
    #expect(!question.isPending()) // Session records can never authorize an executable action.
    let accepted = try record(["type": "function_call_output", "call_id": "question-a", "output": "{\"accepted\":true}"])
    #expect(decoder.decode(accepted).isEmpty)
    let rawID = String(decoding: try JSONSerialization.data(withJSONObject: ["request_user_input_async", "question-a", 0]), as: UTF8.self)
    let replies = try JSONSerialization.data(withJSONObject: [["questionItemId": rawID, "answer": "PNG"]])
    let text = "<send_user_message_question_reply>" + String(decoding: replies, as: UTF8.self) + "</send_user_message_question_reply>"
    #expect(decoder.decode(try record(["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]])).isEmpty)
    let resolved = decoder.decode(try record(["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]))
    #expect(resolved.first?.resolvesID == question.id); #expect(resolved.first?.resolution == "Answered in Codex")
    #expect(decoder.decode(try record(["type": "reasoning", "text": "private"])).isEmpty)
    #expect(decoder.decode(Data("malformed".utf8)).isEmpty)
}

@Test func sessionLineReaderWaitsForCompleteLinesAndSkipsOversizedRecords() {
    var lines = CodexSessionLines()
    #expect(lines.append(Data("part".utf8)).isEmpty)
    #expect(lines.append(Data("ial\nnext\n".utf8)) == [Data("partial".utf8), Data("next".utf8)])
    #expect(lines.append(Data(repeating: 65, count: CodexBridgeStore.maximumBytes + 1)).isEmpty)
    #expect(lines.append(Data("\nvalid\n".utf8)) == [Data("valid".utf8)])
}

@Test func multiQuestionPromptClearsOnlyAfterEveryQuestionIsAnswered() throws {
    var decoder = CodexSessionDecoder(threadID: UUID().uuidString)
    let args = try JSONSerialization.data(withJSONObject: ["questions": [["title": "One?"], ["title": "Two?"]]])
    let events = decoder.decode(try record(["type": "function_call", "name": "request_user_input_async", "call_id": "multi", "arguments": String(decoding: args, as: UTF8.self)]))
    #expect(events.count == 1)
    for index in 0..<2 {
        let rawID = String(decoding: try JSONSerialization.data(withJSONObject: ["request_user_input_async", "multi", index]), as: UTF8.self)
        let body = String(decoding: try JSONSerialization.data(withJSONObject: [["questionItemId": rawID, "answer": "Yes"]]), as: UTF8.self)
        let text = "<send_user_message_question_reply>" + body + "</send_user_message_question_reply>"
        let resolved = decoder.decode(try record(["type": "message", "role": "user", "content": [["text": text]]]))
        #expect(resolved.count == (index == 0 ? 0 : 1))
    }
}

@Test func sessionReaderImportsOnlyNewEventsAndHandlesNewSessionsAndPartialWrites() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SortMyMac-Sessions-Test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let formatter = DateFormatter(); formatter.dateFormat = "yyyy/MM/dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
    let folder = root.appendingPathComponent(formatter.string(from: Date()))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let id = UUID().uuidString, file = folder.appendingPathComponent("rollout-test-" + id + ".jsonl")
    let meta = try record(["id": id, "cwd": "/tmp/fixture"], kind: "session_meta")
    try (meta + questionRecord("old-question")).write(to: file)
    let reader = CodexSessionReader(root: root)
    #expect(await reader.poll().isEmpty)
    let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
    try handle.seekToEnd()
    let fresh = try questionRecord("new-question")
    try handle.write(contentsOf: fresh.prefix(fresh.count / 2))
    #expect(await reader.poll().isEmpty)
    try handle.write(contentsOf: fresh.suffix(fresh.count - fresh.count / 2))
    let received = await reader.poll()
    #expect(received.count == 1); #expect(received.first?.threadID == id); #expect(received.first?.project == "/tmp/fixture")
    #expect(await reader.poll().isEmpty)
    let other = folder.appendingPathComponent("rollout-test-" + UUID().uuidString + ".jsonl")
    try questionRecord("first-question-in-new-session").write(to: other)
    _ = await reader.poll()
    #expect(await reader.poll().count == 1)
    // An atomically replaced file is baselined again, without replaying old questions.
    try (meta + questionRecord("replaced-history")).write(to: file, options: .atomic)
    #expect(await reader.poll().isEmpty)
}
