import AppKit
import Combine
import BetterNotchCore

struct CodexAnswerDraft {
    var selected: String?
    var custom = ""
}

@MainActor
final class CodexModel: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var installed = false
    @Published private(set) var events: [CodexEvent] = []
    @Published private(set) var resolutions: [UUID: String] = [:]
    @Published private(set) var sending = Set<UUID>()
    @Published var selectedID: UUID?
    @Published var answerDrafts: [UUID: [String: CodexAnswerDraft]] = [:]
    @Published var message = ""
    @Published var now = Date()
    @Published var lastReceived: Date?
    @Published var readDesktopQuestions: Bool { didSet { defaults.set(readDesktopQuestions, forKey: "codexDesktopQuestions") } }
    @Published private(set) var replyErrors: [UUID: String] = [:]
    @Published private(set) var unconfirmedReplies = Set<UUID>()
    var onPendingChanged: (() -> Void)?
    var onHandoff: (() -> Void)?
    private var poll: Task<Void, Never>?
    private var pollID = UUID()
    private let defaults: UserDefaults
    let store: CodexBridgeStore
    let hooksURL: URL
    private let sessionsRoot: URL
    private let replySender: @Sendable (CodexEvent, [String: String]) async throws -> Void
    private var replyTasks: [UUID: Task<Void, Never>] = [:]
    var selected: CodexEvent? { events.first { $0.id == selectedID } }
    var attentionCount: Int { events.filter { attention($0) }.count }
    var status: String { !enabled ? "Off" : lastReceived == nil ? "Waiting for Codex" : "Receiving Codex activity" }
    /// Only requests awaiting the user are visible. Routine messages never become cards.
    var visible: [CodexEvent] {
        Dictionary(grouping: events.filter { attention($0) }, by: \.threadID).values.compactMap { history in
            let newest = history.sorted { $0.createdAt > $1.createdAt }
            return newest.first { $0.kind == .approval } ?? newest.first
        }.sorted { left, right in
            if attention(left) != attention(right) { return attention(left) }
            return left.createdAt > right.createdAt
        }
    }
    func latestDiff(for thread: String) -> CodexEvent? { events.last { $0.threadID == thread && !$0.diff.isEmpty } }
    init(defaults: UserDefaults = .standard, store: CodexBridgeStore = .standard, hooksURL: URL? = nil, sessionsRoot: URL = CodexSessionReader.standardRoot, replySender: @escaping @Sendable (CodexEvent, [String: String]) async throws -> Void = { event, answers in try await CodexDesktopReply().submit(event: event, answers: answers) }) {
        self.defaults = defaults; self.store = store
        self.sessionsRoot = sessionsRoot
        self.replySender = replySender
        readDesktopQuestions = defaults.object(forKey: "codexDesktopQuestions") as? Bool ?? true
        self.hooksURL = hooksURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json")
        enabled = defaults.bool(forKey: "codexNotchEnabled")
        installed = CodexHookInstaller.isInstalled(at: self.hooksURL)
    }
    func attention(_ event: CodexEvent) -> Bool {
        guard resolutions[event.id] == nil else { return false }
        return event.kind == .approval ? event.isPending(at: now) : event.kind == .question
    }
    func start() {
        guard enabled, poll == nil else { return }
        let generation = UUID(); pollID = generation
        let store = store
        let sessionsRoot = sessionsRoot
        poll = Task { [weak self] in
            var sessions: CodexSessionReader?
            do {
                try await Task.detached { try store.prepare() }.value
                while !Task.isCancelled {
                    let incoming = try await Task.detached { try store.heartbeat(); return try store.consume() }.value
                    let questions: [CodexEvent]
                    if self?.readDesktopQuestions == true {
                        if sessions == nil { sessions = CodexSessionReader(root: sessionsRoot) }
                        questions = await sessions?.poll() ?? []
                    } else { sessions = nil; questions = [] }
                    guard let self, !Task.isCancelled else { break }
                    now = Date(); ingest(incoming + (readDesktopQuestions ? questions : []))
                    try await Task.sleep(for: .milliseconds(500))
                }
            } catch is CancellationError { }
            catch { self?.message = "Could not open the local Codex inbox. \(error.localizedDescription)" }
            if self?.pollID == generation { store.stop(); self?.poll = nil }
        }
    }
    func setEnabled(_ value: Bool) {
        enabled = value; defaults.set(value, forKey: "codexNotchEnabled")
        if value { start() } else { stop(); events = []; resolutions = [:]; sending = []; answerDrafts = [:]; selectedID = nil; lastReceived = nil; onPendingChanged?() }
    }
    func stop() { pollID = UUID(); poll?.cancel(); poll = nil; store.stop(); replyTasks.values.forEach { $0.cancel() }; replyTasks = [:] }
    func install() {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/BetterNotchCodexBridge")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { message = "Use the packaged BetterNotch app to install Codex hooks."; return }
        do {
            try store.prepare()
            try CodexHookInstaller.update(at: hooksURL, helper: helper, inbox: store.root, install: true)
            installed = true; setEnabled(true)
            message = "Hooks installed. Review and trust them in Codex with /hooks, then start a new turn. Existing hooks were preserved and backed up."
        } catch { message = "Hooks were not installed. \(error.localizedDescription)" }
    }
    func uninstall() {
        do {
            try CodexHookInstaller.update(at: hooksURL, helper: URL(fileURLWithPath: "/unused"), inbox: store.root, install: false)
            installed = false; setEnabled(false); message = "BetterNotch hooks removed. Other hooks were preserved."
        } catch { message = "Could not remove hooks. \(error.localizedDescription)" }
    }
    func ingest(_ incoming: [CodexEvent]) {
        let previous = Set(events.map(\.id))
        for event in incoming {
            lastReceived = now
            if message.hasPrefix("Hooks installed.") { message = "" }
            if event.kind == .resolved, let id = event.resolvesID {
                events.removeAll { $0.id == id && $0.threadID == event.threadID }
                continue
            }
            guard !events.contains(where: { $0.id == event.id }) else { continue }
            if event.kind == .answered {
                events.removeAll { $0.threadID == event.threadID && $0.turnID == event.turnID && $0.kind == .question }
                continue
            }
            if event.kind == .interrupted { events.removeAll { $0.threadID == event.threadID }; continue }
            if event.kind == .completed {
                events.removeAll { $0.threadID == event.threadID && $0.kind == .approval && $0.turnID == event.turnID }
                continue
            }
            guard event.kind == .approval || event.kind == .question else { continue }
            if event.kind == .approval && !event.isPending(at: now) { continue }
            events.append(event)
            // Keep bounded history, retaining unanswered requests ahead of routine updates.
            while events.count > 80 {
                if let index = events.firstIndex(where: { !attention($0) }) { events.remove(at: index) }
                else { events.removeFirst() }
            }
        }
        events.removeAll { $0.kind == .approval && !$0.isPending(at: now) }
        let ids = Set(events.map(\.id)); resolutions = resolutions.filter { ids.contains($0.key) }
        answerDrafts = answerDrafts.filter { ids.contains($0.key) }
        sending.formIntersection(ids)
        replyErrors = replyErrors.filter { ids.contains($0.key) }; unconfirmedReplies.formIntersection(ids)
        for id in Array(replyTasks.keys) where !ids.contains(id) { replyTasks.removeValue(forKey: id)?.cancel() }
        if let selectedID, !ids.contains(selectedID) { self.selectedID = visible.first?.id }
        if previous != ids { onPendingChanged?() }
    }
    func respond(_ choice: CodexDecision.Choice, to event: CodexEvent) {
        guard attention(event), event.isPending(at: Date()), !sending.contains(event.id) else { return }
        do {
            try store.respond(CodexDecision(event: event, choice: choice), to: event)
            sending.insert(event.id); message = ""
        } catch { message = "This request is no longer available here. Continue in Codex." }
    }
    func canSubmit(_ event: CodexEvent) -> Bool {
        event.kind == .question && event.questionCallID != nil && !sending.contains(event.id) && !unconfirmedReplies.contains(event.id) && attention(event) && event.questions.allSatisfy {
            $0.isSecret != true && !(answerValue(event, question: $0.id)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    func answerValue(_ event: CodexEvent, question: String) -> String {
        let draft = answerDrafts[event.id]?[question] ?? CodexAnswerDraft()
        return draft.custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? draft.selected ?? "" : draft.custom
    }
    func submitAnswers(_ event: CodexEvent) {
        guard canSubmit(event) else { return }
        let answers = Dictionary(uniqueKeysWithValues: event.questions.map { ($0.id, answerValue(event, question: $0.id)) })
        sending.insert(event.id); replyErrors.removeValue(forKey: event.id)
        let sender = replySender
        replyTasks[event.id] = Task { [weak self] in
            defer { self?.replyTasks.removeValue(forKey: event.id) }
            do {
                try await sender(event, answers)
                // The actual accepted user-message event is the confirmation, not an IPC success alone.
                try await Task.sleep(for: .seconds(6))
                guard let self, events.contains(where: { $0.id == event.id }), !Task.isCancelled else { return }
                sending.remove(event.id); unconfirmedReplies.insert(event.id); replyErrors[event.id] = CodexReplyError.unconfirmed.localizedDescription
            } catch is CancellationError { }
            catch {
                guard let self, events.contains(where: { $0.id == event.id }) else { return }
                sending.remove(event.id)
                if case CodexReplyError.unconfirmed = error { unconfirmedReplies.insert(event.id) }
                replyErrors[event.id] = error.localizedDescription
            }
        }
    }
    func openCodex(_ event: CodexEvent? = nil) {
        if let event, event.isPending(), resolutions[event.id] == nil { respond(.codex, to: event) }
        // Use only validated UUIDs in a deep link; never open arbitrary URLs supplied by tools.
        if let event, UUID(uuidString: event.threadID) != nil,
           let url = URL(string: "codex://threads/" + event.threadID) { NSWorkspace.shared.open(url) }
        else if let url = URL(string: "codex://") { NSWorkspace.shared.open(url) }
        onHandoff?()
    }
    func clearFinished() {
        events.removeAll { !attention($0) }
        let retained = Set(events.map(\.id)); resolutions = resolutions.filter { retained.contains($0.key) }; answerDrafts = answerDrafts.filter { retained.contains($0.key) }
    }
}
