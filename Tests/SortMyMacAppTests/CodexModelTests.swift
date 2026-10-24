import Foundation
import Testing
import SortMyMacCore
@testable import SortMyMac

@Test @MainActor func codexInboxOnlyResolvesQuestionsInTheMatchingTurnAndWaitsForAcknowledgement() throws {
    let suite = UserDefaults(suiteName: "SortMyMac-Codex-Test-" + UUID().uuidString)!
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SortMyMac-Codex-Test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CodexBridgeStore(root: root); try store.prepare(); try store.heartbeat()
    let model = CodexModel(defaults: suite, store: store, hooksURL: root.appendingPathComponent("hooks.json"))
    let question = CodexEvent(kind: .question, threadID: "a", turnID: "one", title: "Question")
    let permission = CodexEvent(kind: .approval, threadID: "a", turnID: "one", title: "Approval", expiresAt: Date().addingTimeInterval(90))
    model.ingest([question, permission]); #expect(model.attentionCount == 2)
    model.ingest([CodexEvent(kind: .answered, threadID: "a", turnID: "two", title: "Other turn")])
    #expect(model.attentionCount == 2)
    model.respond(.deny, to: permission)
    #expect(model.sending.contains(permission.id)); #expect(model.resolutions[permission.id] == nil)
    model.ingest([CodexEvent(kind: .resolved, threadID: "a", title: "Declined", resolvesID: permission.id, resolution: "Declined")])
    #expect(model.attentionCount == 1); #expect(!model.sending.contains(permission.id))
    model.ingest([CodexEvent(kind: .answered, threadID: "a", turnID: "one", title: "Answered")])
    #expect(model.attentionCount == 0)
    model.setEnabled(false); #expect(model.events.isEmpty); #expect(!store.isAvailable())
}

@Test @MainActor func codexInboxIgnoresRoutineMessagesAndBoundsPendingRequests() {
    let suite = UserDefaults(suiteName: "SortMyMac-Codex-Test-" + UUID().uuidString)!
    let model = CodexModel(defaults: suite)
    let event = CodexEvent(kind: .completed, threadID: "a", title: "Done")
    model.ingest([event, event]); #expect(model.events.isEmpty)
    model.ingest((0..<100).map { CodexEvent(kind: .question, threadID: "\($0)", title: "Question") })
    #expect(model.events.count == 80)
    #expect(NotchRoute.codex.isLarge == false); #expect(NotchRoute.codexDiff.isLarge)
}

@Test @MainActor func codexOnlyShowsPendingInputAndClearsItOnResolution() {
    let suite = UserDefaults(suiteName: "SortMyMac-Codex-Test-" + UUID().uuidString)!
    let model = CodexModel(defaults: suite)
    model.message = "Hooks installed. Review and trust…"
    model.ingest([CodexEvent(kind: .working, threadID: "chat-a", title: "Working"), CodexEvent(kind: .working, threadID: "chat-a", title: "Working again")])
    #expect(model.visible.isEmpty); #expect(model.message.isEmpty)
    let question = CodexEvent(kind: .question, threadID: "chat-a", title: "Question")
    model.ingest([question, CodexEvent(kind: .completed, threadID: "chat-a", title: "Finished"), CodexEvent(kind: .working, threadID: "chat-b", title: "Other chat")])
    #expect(model.visible.count == 1); #expect(model.visible.first?.id == question.id); #expect(model.attentionCount == 1)
    model.ingest((0..<100).map { CodexEvent(kind: .working, threadID: "chat-a", title: "Update \($0)") })
    #expect(model.visible.first?.id == question.id)
    model.ingest([CodexEvent(kind: .resolved, threadID: "chat-a", title: "Answered", resolvesID: question.id, resolution: "Answered in Codex")])
    #expect(model.attentionCount == 0); #expect(model.visible.isEmpty); #expect(model.events.isEmpty)
}

@Test @MainActor func codexResolutionClearsSelectionDraftsAndNotifiesThePanel() {
    let suite = UserDefaults(suiteName: "SortMyMac-Codex-Test-" + UUID().uuidString)!
    let model = CodexModel(defaults: suite)
    var changes = 0; model.onPendingChanged = { changes += 1 }
    let question = CodexEvent(kind: .question, threadID: "chat", title: "Question")
    model.ingest([question]); model.selectedID = question.id
    model.answerDrafts[question.id] = ["q": CodexAnswerDraft(selected: "PNG")]
    model.ingest([CodexEvent(kind: .working, threadID: "chat", title: "Working")])
    #expect(changes == 1); #expect(model.selected?.id == question.id)
    model.ingest([CodexEvent(kind: .resolved, threadID: "other-chat", title: "Wrong thread", resolvesID: question.id)])
    #expect(model.attentionCount == 1)
    model.ingest([CodexEvent(kind: .resolved, threadID: "chat", title: "Answered", resolvesID: question.id)])
    #expect(changes == 2); #expect(model.selected == nil); #expect(model.answerDrafts.isEmpty); #expect(model.visible.isEmpty)
}

private actor ReplyCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

@Test @MainActor func notchAnswerSendsOnceAndWaitsForActualCodexConfirmation() async throws {
    let suite = UserDefaults(suiteName: "SortMyMac-Codex-Test-" + UUID().uuidString)!
    let counter = ReplyCounter()
    let model = CodexModel(defaults: suite, replySender: { _, _ in await counter.record() })
    let questions = try JSONDecoder().decode([CodexQuestion].self, from: Data(#"[{"id":"q","question":"Which output?"}]"#.utf8))
    let event = CodexEvent(kind: .question, threadID: "chat", title: "Question", questions: questions, questionCallID: "call-test")
    model.ingest([event]); model.answerDrafts[event.id] = ["q": CodexAnswerDraft(selected: "PNG")]
    model.submitAnswers(event); model.submitAnswers(event)
    for _ in 0..<30 { if await counter.count == 1 { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await counter.count == 1); #expect(model.sending.contains(event.id)); #expect(model.visible.count == 1)
    model.ingest([CodexEvent(kind: .resolved, threadID: "chat", title: "Answered", resolvesID: event.id)])
    #expect(model.visible.isEmpty); #expect(!model.sending.contains(event.id)); #expect(model.answerDrafts.isEmpty)
    model.stop()
}

@Test @MainActor func anUnconfirmedNotchAnswerCannotBeBlindlyRetried() async throws {
    let suite = UserDefaults(suiteName: "SortMyMac-Codex-Test-" + UUID().uuidString)!
    let model = CodexModel(defaults: suite, replySender: { _, _ in throw CodexReplyError.unconfirmed })
    let questions = try JSONDecoder().decode([CodexQuestion].self, from: Data(#"[{"id":"q","question":"Which output?"}]"#.utf8))
    let event = CodexEvent(kind: .question, threadID: "chat", title: "Question", questions: questions, questionCallID: "call-test")
    model.ingest([event]); model.answerDrafts[event.id] = ["q": CodexAnswerDraft(selected: "PNG")]
    model.submitAnswers(event)
    for _ in 0..<30 { if model.unconfirmedReplies.contains(event.id) { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(model.unconfirmedReplies.contains(event.id)); #expect(!model.canSubmit(event)); #expect(model.visible.count == 1)
    model.stop()
}
