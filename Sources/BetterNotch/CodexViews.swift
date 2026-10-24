import SwiftUI
import AppKit
import BetterNotchCore

struct CodexInboxView: View {
    @ObservedObject var codex: CodexModel
    @ObservedObject var hub: HubModel
    var body: some View {
        VStack(alignment: .leading, spacing: HubUI.related) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex").font(HubUI.title)
                    Text("Questions & permissions").font(HubUI.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let event = codex.selected {
                if codex.visible.count > 1 || codex.latestDiff(for: event.threadID) != nil {
                HStack {
                    if codex.visible.count > 1 { Button { codex.selectedID = nil } label: { Label("Requests", systemImage: "chevron.left") } }
                    Spacer()
                    if let diff = codex.latestDiff(for: event.threadID) { Button("Review diff") { codex.selectedID = diff.id; hub.route = .codexDiff } }
                    if event.kind != .question && event.kind != .approval { Button("Open Codex") { codex.openCodex(event) } }
                }
                }
                ScrollView {
                    CodexEventDetail(codex: codex, event: event).id(event.id).frame(maxWidth: .infinity, alignment: .leading)
                }
                if event.kind == .approval { CodexApprovalControls(codex: codex, event: event) }
                if event.kind == .question { CodexQuestionControls(codex: codex, event: event) }
            } else if codex.events.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(codex.enabled ? "Nothing needs your input" : "Enable Codex prompts").font(.headline)
                    Text(codex.enabled ? "Questions and permission requests appear here, then disappear when resolved." : "Set up Codex to see questions and permission requests here.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
                    if !codex.enabled { Button("Set up Codex") { hub.owner?.settingsPage = "Codex"; hub.owner?.showSettings() }.buttonStyle(.borderedProminent) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: HubUI.gap) {
                        ForEach(codex.visible) { event in
                            Button { codex.selectedID = event.id } label: { CodexEventRow(codex: codex, event: event) }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

private struct CodexEventRow: View {
    @ObservedObject var codex: CodexModel
    let event: CodexEvent
    private var symbol: String {
        switch event.kind {
        case .approval: "hand.raised.fill"; case .question: "questionmark.bubble.fill"; case .changes: "doc.text"
        case .working: "ellipsis"; case .completed, .answered: "checkmark"; case .interrupted: "pause.fill"; case .resolved: "checkmark"
        }
    }
    var body: some View {
        HStack(spacing: HubUI.related) {
            Image(systemName: symbol).foregroundStyle(codex.attention(event) ? .orange : .cyan)
                .frame(width: 32, height: 32).background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(event.project.isEmpty ? "Local Codex chat" : URL(fileURLWithPath: event.project).lastPathComponent).font(HubUI.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let resolution = codex.resolutions[event.id] { Text(resolution).font(HubUI.caption).foregroundStyle(.secondary) }
            else if codex.attention(event) { Text("Needs you").font(HubUI.caption.weight(.medium)).foregroundStyle(.orange) }
            else { Text(event.createdAt, style: .time).font(HubUI.caption).foregroundStyle(.secondary) }
            Image(systemName: "chevron.right").font(HubUI.caption).foregroundStyle(.secondary)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: HubUI.radius))
            .contentShape(RoundedRectangle(cornerRadius: HubUI.radius))
    }
}

private struct CodexEventDetail: View {
    @ObservedObject var codex: CodexModel
    let event: CodexEvent
    var body: some View {
        VStack(alignment: .leading, spacing: HubUI.related) {
            if event.kind != .question {
                Text(event.title).font(.headline)
                if !event.project.isEmpty { Text(event.project).font(HubUI.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            if !event.message.isEmpty { Text(event.message).textSelection(.enabled) }
            if !event.command.isEmpty {
                Text(event.command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).hubPanel()
            }
            if !event.diff.isEmpty { Label("File changes available in Review diff", systemImage: "doc.text").foregroundStyle(.secondary) }
            if event.kind == .question {
                if let resolution = codex.resolutions[event.id] { Label(resolution, systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                else {
                ForEach(event.questions) { question in
                    CodexQuestionCard(question: question, draft: Binding(get: { codex.answerDrafts[event.id]?[question.id] ?? CodexAnswerDraft() }, set: { codex.answerDrafts[event.id, default: [:]][question.id] = $0 }))
                        .disabled(codex.sending.contains(event.id))
                }
                }
            }
        }.padding(.bottom, 4)
    }
}

private struct CodexApprovalControls: View {
    @ObservedObject var codex: CodexModel
    let event: CodexEvent
    var body: some View {
        VStack(alignment: .leading, spacing: HubUI.gap) {
            if let resolution = codex.resolutions[event.id] { Label(resolution, systemImage: "checkmark.circle") }
            else if codex.sending.contains(event.id) { HStack { ProgressView().controlSize(.mini); Text("Sending your decision…") } }
            else if event.isPending(at: codex.now) {
                Text("Applies once to this action. Other Codex policies still apply.").font(HubUI.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Decline") { codex.respond(.deny, to: event) }
                    Button("Review in Codex") { codex.openCodex(event) }
                    Spacer()
                    Button("Allow once") { codex.respond(.allow, to: event) }.buttonStyle(.borderedProminent)
                }
            } else { Text("Continue this request in Codex.").foregroundStyle(.secondary) }
        }.hubActionBar()
    }
}

private struct CodexQuestionControls: View {
    @ObservedObject var codex: CodexModel
    let event: CodexEvent
    var body: some View {
        VStack(alignment: .leading, spacing: HubUI.gap) {
            if let error = codex.replyErrors[event.id] { Text(error).font(HubUI.caption).foregroundStyle(.orange) }
            HStack {
                Button("Open in Codex") { codex.openCodex(event) }
                Spacer()
                if codex.sending.contains(event.id) { ProgressView().controlSize(.small); Text("Sending answer…").font(HubUI.caption) }
                else if event.questionCallID != nil { Button("Send answer") { codex.submitAnswers(event) }.buttonStyle(.borderedProminent).disabled(!codex.canSubmit(event)) }
                else { Text("Answer this request in Codex.").font(HubUI.caption).foregroundStyle(.secondary) }
            }
        }.hubActionBar()
    }
}

private struct CodexQuestionCard: View {
    let question: CodexQuestion
    @Binding var draft: CodexAnswerDraft
    var body: some View {
        VStack(alignment: .leading, spacing: HubUI.gap) {
            if let header = question.header { Text(header).font(HubUI.caption).foregroundStyle(.secondary) }
            Text(question.question).font(.system(size: 13, weight: .semibold))
            ForEach(Array((question.options ?? []).enumerated()), id: \.offset) { index, option in
                Button { draft.selected = option.label; draft.custom = "" } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: draft.selected == option.label && draft.custom.isEmpty ? "largecircle.fill.circle" : "circle").foregroundStyle(draft.selected == option.label ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(index + 1). \(option.label)").fontWeight(.medium)
                            if let description = option.description { Text(description).font(HubUI.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.primary.opacity(draft.selected == option.label ? 0.10 : 0.04), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityLabel(option.label).accessibilityAddTraits(draft.selected == option.label ? .isSelected : [])
            }
            if question.isSecret == true {
                Text("Enter private information directly in Codex.").font(HubUI.caption).foregroundStyle(.secondary)
            }
            else {
                TextField("Write your own answer", text: $draft.custom)
                    .onChange(of: draft.custom) { _, value in if !value.isEmpty { draft.selected = nil } }
            }
        }.hubPanel()
    }
}

struct CodexDiffView: View {
    @ObservedObject var codex: CodexModel
    @ObservedObject var hub: HubModel
    var body: some View {
        VStack(alignment: .leading, spacing: HubUI.related) {
            HStack {
                Button { hub.route = .codex } label: { Label("Codex", systemImage: "chevron.left") }
                Text("File changes").font(HubUI.title)
                Spacer()
                Button("Open Codex") { codex.openCodex(codex.selected) }
            }
            Text("Hook preview · Review the execution result in Codex. File contents are never changed here.").font(HubUI.caption).foregroundStyle(.secondary)
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array((codex.selected?.diff ?? "").components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                .foregroundStyle(line.hasPrefix("+") ? .green : line.hasPrefix("-") ? .red : line.hasPrefix("@@") || line.hasPrefix("***") ? .cyan : .primary)
                                .fixedSize(horizontal: true, vertical: true)
                                .padding(.horizontal, 10).padding(.vertical, 2).frame(minWidth: geometry.size.width, alignment: .leading)
                                .background(line.hasPrefix("+") ? Color.green.opacity(0.07) : line.hasPrefix("-") ? Color.red.opacity(0.07) : .clear)
                        }
                    }
                }
            }.background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: HubUI.radius))
        }
    }
}

struct CodexSettingsView: View {
    @ObservedObject var codex: CodexModel
    var body: some View {
        Form {
            Section("Codex in the notch") {
                Toggle("Receive local Codex activity", isOn: Binding(get: { codex.enabled }, set: codex.setEnabled))
                Toggle("Read new desktop question events", isOn: $codex.readDesktopQuestions)
                LabeledContent("Connection", value: codex.status)
                Text("Only questions and permission requests appear in the notch. Resolved requests are removed and the panel closes when nothing needs your input. Routine messages and working/finished updates are hidden. New question/reply events are read locally from active Codex session files; old conversations and reasoning are not imported. Nothing is sent to Cloudflare.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Setup") {
                Button(codex.installed ? "Update Codex hooks" : "Install Codex hooks", action: codex.install)
                Text("After installing, review and trust the BetterNotch hooks in Codex with /hooks, then start a new turn. Existing hooks are preserved and backed up. Hooks require a compatible local Codex version.").font(.caption).foregroundStyle(.secondary)
                if codex.installed { Button("Remove BetterNotch hooks", action: codex.uninstall) }
                if !codex.message.isEmpty { Text(codex.message).font(.caption).textSelection(.enabled) }
            }
            Section("Interactions") {
                Text("Allow once and Decline apply only to a live permission request. After 90 seconds, or if BetterNotch disconnects, the normal Codex prompt continues. For supported desktop questions, select your answers and press Send answer. The prompt clears after Codex records your reply.").font(.caption).foregroundStyle(.secondary)
                Text("Question previews read new local session events. Sending uses Codex’s local desktop coordination protocol and verifies the target chat and pending question first. These version-specific formats may change; unsupported or unconfirmed delivery leaves Open in Codex available. Unconfirmed sends are never automatically retried. Private answers must be entered directly in Codex.").font(.caption).foregroundStyle(.secondary)
                Link("Codex hook documentation", destination: URL(string: "https://learn.chatgpt.com/docs/hooks")!)
            }
        }.formStyle(.grouped)
    }
}
