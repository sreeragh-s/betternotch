import AppKit
import SortMyMacCore
import SwiftUI

struct NotchSurface: Shape {
    func path(in r: CGRect) -> Path {
        let wing: CGFloat = min(14, r.height / 3)
        let corner: CGFloat = min(25, r.height / 2)
        return Path { p in
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: r.width, y: 0))
            p.addQuadCurve(to: CGPoint(x: r.width - wing, y: wing), control: CGPoint(x: r.width - wing, y: 0))
            p.addLine(to: CGPoint(x: r.width - wing, y: r.height - corner))
            p.addQuadCurve(to: CGPoint(x: r.width - wing - corner, y: r.height), control: CGPoint(x: r.width - wing, y: r.height))
            p.addLine(to: CGPoint(x: wing + corner, y: r.height))
            p.addQuadCurve(to: CGPoint(x: wing, y: r.height - corner), control: CGPoint(x: wing, y: r.height))
            p.addLine(to: CGPoint(x: wing, y: wing))
            p.addQuadCurve(to: .zero, control: CGPoint(x: wing, y: 0))
            p.closeSubpath()
        }
    }
}

struct SoftPress: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct CircleControl: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(hover ? .primary : .secondary).frame(width: HubUI.control, height: HubUI.control)
                .background(Color.primary.opacity(hover ? 0.14 : 0.07), in: Circle())
        }
        .buttonStyle(SoftPress()).onHover { hover = $0 }.help(label).accessibilityLabel(label)
    }
}

struct NotchView: View {
    @ObservedObject var model: AppModel
    var body: some View { HubShell(model: model, hub: model.hub) }
}

struct HubShell: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hub: HubModel
    @ObservedObject var codex: CodexModel
    init(model: AppModel, hub: HubModel) { self.model = model; self.hub = hub; self.codex = hub.codex }
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchSurface().fill(.black)
                    .overlay(NotchSurface().stroke(Color.primary.opacity(model.expanded ? 0.10 : 0), lineWidth: 1))
                if model.expanded && model.geometry.hasCutout {
                    NotchSurface().fill(.black).frame(width: model.geometry.restingSize.width, height: model.geometry.restingSize.height).accessibilityHidden(true)
                }
                if model.contentVisible {
                    VStack(spacing: HubUI.section) {
                        header
                        if model.dropTargeted { dropTarget }
                        else { content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) }
                        if !hub.error.isEmpty {
                            HStack(alignment: .top) {
                                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                                Text(hub.error).font(.caption).textSelection(.enabled).lineLimit(3).help(hub.error)
                                Spacer(); Button { hub.error = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss error")
                            }
                        }
                        if hub.route != .recordingSetup { footer }
                    }
                    .padding(.horizontal, 32).padding(.top, model.geometry.restingSize.height + HubUI.related).padding(.bottom, HubUI.inset)
                    .transition(.opacity)
                } else if !model.expanded { collapsed }
            }
            .frame(width: model.expanded ? model.geometry.expandedSize.width : model.geometry.restingSize.width,
                   height: model.expanded ? model.geometry.expandedSize.height : model.geometry.restingSize.height)
            .clipShape(NotchSurface())
            .onHover { if $0 && !model.expanded { model.notch?.expand() } }
            .onTapGesture { if !model.expanded { model.notch?.expand(immediate: true) } }
            .shadow(color: .black.opacity(model.expanded ? (colorScheme == .dark ? 0.45 : 0.18) : 0), radius: 12, y: 6)
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .foregroundStyle(.primary)
            .hubControls()
            .environment(\.colorScheme, .dark)
            .onChange(of: hub.isRecording) { _, _ in model.notch?.resizeForContent() }
            .onChange(of: hub.currentJobs.map(\.id)) { _, _ in model.notch?.resizeForContent() }
            .onChange(of: model.isBusy) { _, _ in model.notch?.resizeForContent() }
            .onChange(of: codex.attentionCount) { _, _ in model.notch?.resizeForContent() }
    }
    private var header: some View {
        HStack(spacing: 10) {
            Button { hub.route = .home } label: { Label("SortMyMac", systemImage: "square.stack.3d.up.fill").font(.system(size: 13, weight: .semibold)) }.buttonStyle(.plain)
            Spacer()
            if hub.isRecording {
                Button { if let meeting = hub.activeMeeting { hub.openMeeting(meeting) } } label: {
                    HStack(spacing: 5) { Circle().fill(hub.recordingPaused ? .orange : .red).frame(width: 6, height: 6); Text(hub.recordingPaused ? "Paused" : Duration.seconds(hub.elapsed).formatted(.time(pattern: .minuteSecond))).monospacedDigit() }.font(.caption)
                }.buttonStyle(.plain).accessibilityLabel("Show active recording")
            }
            CircleControl(symbol: "tray.full", label: "Shelf") { hub.route = .shelf }
            CircleControl(symbol: "waveform", label: "Meetings") { hub.route = .meetings }
            CircleControl(symbol: "terminal", label: codex.attentionCount > 0 ? "Codex, \(codex.attentionCount) requests need attention" : "Codex") { hub.route = .codex }
                .overlay(alignment: .topTrailing) {
                    if codex.attentionCount > 0 { Circle().fill(.orange).frame(width: 7, height: 7).accessibilityHidden(true).allowsHitTesting(false) }
                }
            CircleControl(symbol: "gearshape", label: "Settings", action: model.showSettings)
            CircleControl(symbol: "xmark", label: "Close") { model.notch?.collapse(force: true) }
        }
    }
    @ViewBuilder private var content: some View {
        switch hub.route {
        case .home: home
        case .shelf, .fileActions, .results: ShelfView(hub: hub)
        case .editor: ActionEditor(hub: hub)
        case .meetings: MeetingLibraryView(hub: hub)
        case .meetingDetail: MeetingDetailView(hub: hub)
        case .recordingSetup: RecordingSetupView(hub: hub)
        case .models: SpeechModelView(hub: hub)
        case .jobs: JobsView(hub: hub)
        case .organize: organization
        case .codex: CodexInboxView(codex: codex, hub: hub)
        case .codexDiff: CodexDiffView(codex: codex, hub: hub)
        }
    }
    private var home: some View {
        VStack(alignment: .leading, spacing: HubUI.related) {
            Text("A little help. Right here.").font(.system(size: 23, weight: .semibold))
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    HomeToolCard(title: "Record Meeting", symbol: "waveform", detail: hub.isRecording ? "Recording in progress" : "Audio & transcript", compact: !hub.error.isEmpty, palette: .coral) { hub.route = hub.isRecording ? .meetingDetail : .recordingSetup; if hub.isRecording { hub.selectedMeetingID = hub.activeMeetingID } }
                    HomeToolCard(title: "Meetings", symbol: "text.bubble.fill", detail: "Saved transcripts", count: hub.meetings.count, compact: !hub.error.isEmpty, palette: .blue) { hub.route = .meetings }
                    HomeToolCard(title: "File Tools", symbol: "wand.and.stars", detail: "Choose files to begin", compact: !hub.error.isEmpty, palette: .orange, action: hub.chooseFiles)
                }
                GridRow {
                    HomeToolCard(title: "Shelf", symbol: "tray.fill", detail: "Parked files", count: hub.shelf.filter { !$0.managed }.count, compact: !hub.error.isEmpty, palette: .purple) { hub.route = .shelf }
                    HomeToolCard(title: "Recent Results", symbol: "checkmark", detail: "Ready to drag out", count: hub.shelf.filter(\.managed).count, compact: !hub.error.isEmpty, palette: .green) { hub.route = .results }
                    HomeToolCard(title: "Activity", symbol: "list.bullet.rectangle.fill", detail: model.isBusy ? "Organizing files" : !model.groups.isEmpty ? "Review folders" : "Active jobs", count: hub.currentJobs.count, compact: !hub.error.isEmpty, palette: .slate) { hub.route = model.isBusy || !model.groups.isEmpty ? .organize : .jobs }
                }
            }
        }
    }
    private var dropTarget: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 36)).foregroundStyle(Color.accentColor)
            Text("Drop to see what’s possible").font(.title3.weight(.semibold))
            Text("Choose an action after dropping. Your originals stay in place.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
    }
    private var collapsed: some View {
        HStack {
            if hub.isRecording { Circle().fill(hub.recordingPaused ? .orange : .red).frame(width: 7, height: 7).padding(.leading, 18) }
            else if !hub.currentJobs.isEmpty || model.isBusy { ProgressView().controlSize(.mini).tint(.white).padding(.leading, 18) }
            else if codex.attentionCount > 0 { Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(.orange).padding(.leading, 18) }
            Spacer()
            if hub.isRecording { Text(Duration.seconds(hub.elapsed).formatted(.time(pattern: .minuteSecond))).font(.system(size: 10)).monospacedDigit().foregroundStyle(.white).padding(.trailing, 16) }
            else if codex.attentionCount > 0 { Text("\(codex.attentionCount)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange).padding(.trailing, 18) }
            else if !model.geometry.hasCutout { Text("SortMyMac").font(.system(size: 10)).foregroundStyle(.white); Spacer() }
        }.frame(height: model.geometry.restingSize.height)
    }
    private var footer: some View {
        HStack {
            if hub.loading { ProgressView().controlSize(.mini); Text("Opening local library…") }
            else { Text(hub.isRecording ? "Recording locally · \(hub.activeMeeting?.transcriptStatus ?? "")" : hub.route == .codex || hub.route == .codexDiff ? "Local Codex activity · Decisions are never automatic." : "Files stay in place until you choose an action.").lineLimit(1) }
            Spacer()
            if hub.downloadProgress != nil { Button("Model download") { hub.route = .models } }
            if hub.route != .home && hub.route != .meetings && hub.route != .codex && hub.route != .codexDiff { Button("Home") { hub.route = .home }.keyboardShortcut("h", modifiers: .command) }
        }.font(HubUI.caption).foregroundStyle(.secondary)
    }
    private var organization: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.phase == .analyzing ? "Finding what belongs together." : "A place for everything.").font(.title3.weight(.semibold))
            GroupingReviewView(model: model)
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            if let warning = model.warnings.first { Text(warning).font(.caption).foregroundStyle(.orange) }
            HStack {
                if model.phase == .analyzing { ProgressView().controlSize(.small); Button("Cancel", action: model.cancelOrganization) }
                if model.phase == .grouped || model.phase == .exporting {
                    Label("Drag All Folders", systemImage: "hand.draw.fill").font(.caption.weight(.semibold)).padding(10).background(Color.accentColor.opacity(0.15), in: Capsule())
                        .overlay { FolderDragHandle(groups: model.groups, model: model, label: "Drag all folders to Finder") }
                }
                if model.phase == .completed { Button("Undo move", action: model.showRecovery) }
                if model.phase == .failed { Button("Retry", action: model.organize); Button("Recovery", action: model.showRecovery) }
                Spacer()
                if !model.isBusy { Button("Start over") { model.clear(); hub.route = .home } }
            }
        }
    }
}
