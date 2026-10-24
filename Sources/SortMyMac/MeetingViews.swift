import AppKit
import AVKit
import SortMyMacCore
import SwiftUI

struct RecordingSetupView: View {
    @ObservedObject var hub: HubModel
    var body: some View {
        VStack(alignment: .leading, spacing: HubUI.related) {
            Text("Record a meeting").font(HubUI.title)
            ScrollView {
                VStack(alignment: .leading, spacing: HubUI.related) {
                    Grid(alignment: .leading, horizontalSpacing: HubUI.related, verticalSpacing: HubUI.related) {
                        GridRow {
                            Text("Title").foregroundStyle(.secondary)
                            TextField("Meeting title (optional)", text: $hub.meetingTitle)
                        }
                        GridRow {
                            Text("Audio").foregroundStyle(.secondary)
                            Picker("Audio source", selection: $hub.audioSource) { Text("Microphone + system audio").tag(AudioSource.both); Text("Microphone only").tag(AudioSource.microphone); Text("System audio only").tag(AudioSource.system) }.labelsHidden().frame(maxWidth: .infinity)
                        }
                        if hub.audioSource != .system {
                            GridRow {
                                Text("Microphone").foregroundStyle(.secondary)
                                Picker("Microphone", selection: $hub.microphoneID) { Text("System default").tag(UInt32(0)); ForEach(MeetingRecorder.microphones()) { Text($0.name).tag($0.id) } }.labelsHidden().frame(maxWidth: .infinity)
                            }
                        }
                    }.hubPanel()
                    Label("Recorded and transcribed locally on this Mac.", systemImage: "lock.shield").font(HubUI.caption).foregroundStyle(.secondary)
                    if !hub.installedModels.contains(hub.speechModel) {
                        HStack(spacing: HubUI.gap) {
                            Text("Record now, set up transcription later.").font(HubUI.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Speech models") { hub.route = .models }.fixedSize()
                        }
                    }
                }.padding(2)
            }
            HStack(spacing: HubUI.gap) { Button("Cancel") { hub.route = .home }; Spacer(); if hub.recordingBusy { ProgressView().controlSize(.small) }; Button("Start recording", action: hub.startRecording).buttonStyle(.borderedProminent).disabled(hub.recordingBusy || hub.loading) }.hubActionBar()
        }.frame(maxWidth: .infinity)
    }
}
struct SpeechModelView: View {
    @ObservedObject var hub: HubModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HubUI.section) {
                Text("Local transcription").font(HubUI.title)
                Text("Download a model once. Audio is then transcribed offline using Whisper on this Mac.").font(.callout).foregroundStyle(.secondary)
                ForEach(SpeechModel.choices) { model in
                    HStack {
                        VStack(alignment: .leading) { Text(model.id.capitalized + (model.id == "small" ? " · recommended" : " · lighter")).font(.headline); Text(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if hub.installedModels.contains(model.id) {
                            if hub.speechModel == model.id { Label("Selected", systemImage: "checkmark.circle.fill").font(HubUI.caption).foregroundStyle(Color.accentColor) }
                            else { Button("Use model") { hub.speechModel = model.id; hub.saveLocalSettings() } }
                            Button("Remove", role: .destructive) { hub.removeModel(model.id) }
                        } else { Button("Download") { hub.downloadModel(model) }.disabled(hub.downloadProgress != nil) }
                    }.hubPanel()
                }
                if let progress = hub.downloadProgress { ProgressView(value: progress); HStack { Text("\(Int(progress * 100))% downloaded · checksum verified before install").font(.caption); Spacer(); Button("Cancel") { hub.downloadTask?.cancel() } } }
                HubFormField("Transcription language") { Picker("Language", selection: $hub.language) {
                    ForEach([("Auto detect", "auto"), ("English", "en"), ("Malayalam", "ml"), ("Hindi", "hi"), ("Tamil", "ta"), ("Spanish", "es"), ("French", "fr"), ("German", "de"), ("Japanese", "ja"), ("Chinese", "zh")], id: \.1) { Text($0.0).tag($0.1) }
                }.labelsHidden().onChange(of: hub.language) { _, _ in hub.saveLocalSettings() } }.frame(maxWidth: 320)
                Text("Live text is a draft. Committed segments are saved with timestamps; the final transcript completes after recording stops. Source labels identify microphone/system audio, not individual speakers.").font(.caption).foregroundStyle(.secondary)
            }.padding(2)
        }
    }
}
struct MeetingLibraryView: View {
    @ObservedObject var hub: HubModel
    @State private var search = ""
    private var matchingMeetings: [MeetingRecord] {
        hub.meetings.filter { search.isEmpty || $0.searchableText.localizedCaseInsensitiveContains(search) }.sorted { $0.created > $1.created }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: HubUI.gap) { Text("Meetings").font(HubUI.title); Spacer(); Button("Speech models") { hub.route = .models }; Button("Record meeting") { hub.route = .recordingSetup }.buttonStyle(.borderedProminent) }
            HubSearchField(title: "Search titles and transcripts", text: $search)
            if hub.meetings.isEmpty {
                emptyState("No meetings yet", symbol: "waveform", description: "Record a meeting or choose Transcribe for an audio or video file.")
            } else if matchingMeetings.isEmpty {
                emptyState("No matching meetings", symbol: "magnifyingglass", description: "Try a different title or a word from your transcript.")
            }
            else {
                List(matchingMeetings) { meeting in
                    MeetingLibraryRow(meeting: meeting) { hub.openMeeting(meeting) }
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: HubUI.gap, trailing: 0))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func emptyState(_ title: String, symbol: String, description: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(description).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct MeetingLibraryRow: View {
    let meeting: MeetingRecord
    let open: () -> Void
    @State private var hovered = false
    private var metadata: String {
        meeting.created.formatted(date: .abbreviated, time: .shortened) + " · " + Duration.seconds(meeting.duration).formatted(.time(pattern: .hourMinuteSecond))
    }
    private var statusColor: Color {
        switch meeting.status {
        case .ready: .green
        case .recording: .red
        case .paused, .failed, .interrupted: .orange
        case .finalizing: .accentColor
        }
    }
    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: HubUI.section) {
                icon
                details
                badge
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(HubUI.section).frame(maxWidth: .infinity, minHeight: 84)
            .background(Color.primary.opacity(hovered ? 0.075 : 0.04), in: RoundedRectangle(cornerRadius: HubUI.radius))
            .overlay(RoundedRectangle(cornerRadius: HubUI.radius).strokeBorder(Color.primary.opacity(hovered ? 0.18 : 0.08)))
            .contentShape(RoundedRectangle(cornerRadius: HubUI.radius))
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
            .accessibilityLabel(meeting.title).accessibilityValue(metadata + ", " + meeting.status.rawValue + ", " + meeting.transcriptStatus)
    }
    private var icon: some View {
        Image(systemName: meeting.status == .recording ? "record.circle.fill" : "waveform")
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(meeting.status == .recording ? Color.red : Color.accentColor)
            .frame(width: 44, height: 44)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: HubUI.small) {
            Text(meeting.title).font(HubUI.body.weight(.semibold)).lineLimit(1).help(meeting.title)
            Text(metadata).font(HubUI.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(meeting.transcriptStatus).font(HubUI.caption).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var badge: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 5, height: 5)
            Text(meeting.status.rawValue.capitalized).font(HubUI.caption.weight(.medium))
        }.padding(.horizontal, 10).padding(.vertical, 5)
            .background(statusColor.opacity(0.10), in: Capsule()).fixedSize()
    }
}

struct MeetingDetailView: View {
    @ObservedObject var hub: HubModel
    @State private var player: AVPlayer?
    @State private var title = ""
    @State private var search = ""
    @State private var deleting = false
    var body: some View {
        Group {
            if let meeting = hub.selectedMeeting {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("Meeting title", text: $title).font(HubUI.title).textFieldStyle(.roundedBorder).onSubmit { hub.renameMeeting(meeting.id, title: title) }
                        Button("Save title") { hub.renameMeeting(meeting.id, title: title) }
                        Menu("Export") { ForEach(["txt", "md", "srt", "vtt"], id: \.self) { format in Button(format.uppercased()) { hub.exportTranscript(meeting, format: format) } }; if let url = meeting.audioURL { Button("Save audio…") { saveCopy(url) } } }.fixedSize()
                    }
                    if hub.activeMeetingID == meeting.id { recordingControls }
                    if let error = meeting.error { Text(error).font(.caption).foregroundStyle(.orange) }
                    if let player { VideoPlayer(player: player).frame(height: 65).onDrag { meeting.audioURL.map { NSItemProvider(contentsOf: $0) ?? NSItemProvider() } ?? NSItemProvider() } }
                    HStack(spacing: HubUI.related) { HubSearchField(title: "Find in transcript", text: $search); Text(meeting.transcriptStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 220) }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(meeting.segments.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }.sorted { $0.start < $1.start }) { segment in
                                HStack(alignment: .top, spacing: 10) {
                                    Button(TranscriptExporter.timestamp(segment.start)) { player?.seek(to: CMTime(seconds: segment.start, preferredTimescale: 600)); player?.play() }.font(.caption.monospaced()).frame(width: 100)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(segment.source == .microphone ? "Microphone" : segment.source == .system ? "System audio" : "Imported audio").font(.caption2).foregroundStyle(.secondary)
                                        TextField("Transcript", text: Binding(get: { hub.meetings.first(where: { $0.id == meeting.id })?.segments.first(where: { $0.id == segment.id })?.text ?? segment.text }, set: { hub.editSegment(meeting.id, segmentID: segment.id, text: $0) }), axis: .vertical).textFieldStyle(.plain).font(.system(size: 13))
                                    }
                                }.padding(10).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
                            }
                            if hub.transcribingMeeting == meeting.id, !hub.liveDraft.isEmpty { Text("Draft · " + hub.liveDraft).italic().foregroundStyle(.secondary).padding(10) }
                            if meeting.segments.isEmpty { Text(hub.isRecording ? "Your transcript will appear here as speech is processed." : "Download a speech model, then choose Transcribe.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(24) }
                            if !meeting.summary.isEmpty {
                                Divider(); Text("Summary & action items").font(.headline)
                                TextField("Summary", text: Binding(get: { hub.meetings.first(where: { $0.id == meeting.id })?.summary ?? meeting.summary }, set: { hub.editSummary(meeting.id, text: $0) }), axis: .vertical).textFieldStyle(.plain)
                                SummaryEvidenceView(summary: meeting.summary) { seconds in player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)); player?.play() }
                            }
                        }.padding(2)
                    }
                    HStack {
                        Button("Meetings") { hub.route = .meetings }
                        Button("Transcribe") { hub.retryTranscript(meeting) }.disabled(hub.transcribingMeeting == meeting.id)
                        Menu("More") {
                            if hub.transcribingMeeting == meeting.id { Button("Cancel transcription") { hub.cancelTranscription(meeting) } }
                            Button("Re-transcribe (preserve edits)") { hub.retryTranscript(meeting, redo: true) }
                            if meeting.audioURL == nil, !meeting.chunks.isEmpty { Button("Recover playable audio") { hub.recoverAudio(meeting) } }
                            Button("Generate local summary") { hub.summarizeMeeting(meeting) }
                            Button("Speech models") { hub.route = .models }
                            Button("Show recordings in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: hub.root.appendingPathComponent("Meetings/\(meeting.id.uuidString)").path) }
                            Button("Delete meeting…", role: .destructive) { deleting = true }
                        }.fixedSize()
                        Spacer()
                        Text("\(meeting.segments.count) saved segments").font(.caption).foregroundStyle(.secondary)
                    }.hubActionBar()
                }.task(id: meeting.id) { title = meeting.title; if let url = meeting.audioURL { player = AVPlayer(url: url) } }
                    .onChange(of: meeting.audioURL) { _, url in player?.pause(); player = url.map(AVPlayer.init(url:)) }
                    .onDisappear { player?.pause(); player = nil; hub.renameMeeting(meeting.id, title: title) }
                    .alert("Delete this meeting and its recording?", isPresented: $deleting) { Button("Delete", role: .destructive) { hub.deleteMeeting(meeting) }; Button("Cancel", role: .cancel) {} } message: { Text("The recording folder will move to Trash. Exported copies remain available.") }
            } else { ContentUnavailableView("Choose a meeting", systemImage: "waveform") }
        }
    }
    private var recordingControls: some View {
        HStack(spacing: 16) {
            Circle().fill(hub.recordingPaused ? .orange : .red).frame(width: 8, height: 8)
            Text(Duration.seconds(hub.elapsed).formatted(.time(pattern: .hourMinuteSecond))).monospacedDigit()
            VStack(alignment: .leading) { Text("Mic").font(.caption2); ProgressView(value: Double(min(1, hub.micLevel))) }.frame(width: 70)
            VStack(alignment: .leading) { Text("System").font(.caption2); ProgressView(value: Double(min(1, hub.systemLevel))) }.frame(width: 70)
            Spacer()
            Button(hub.recordingPaused ? "Resume" : "Pause", action: hub.pauseRecording).disabled(hub.recordingBusy)
            Button("Stop & Save") { Task { await hub.stopRecording() } }.buttonStyle(.borderedProminent).disabled(hub.recordingBusy)
        }.padding(10).background(Color.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}
struct JobsView: View {
    @ObservedObject var hub: HubModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Activity & Undo").font(.title2.weight(.semibold))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(hub.jobs.sorted { $0.created > $1.created }) { job in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Label(job.request.kind.title, systemImage: job.request.kind.symbol).font(.headline); Spacer(); Text(job.status.rawValue.capitalized).font(.caption); if [.queued, .running].contains(job.status) { Button("Cancel") { hub.cancelJob(job.id) } } else if [.failed, .interrupted, .canceled].contains(job.status) { Button("Retry") { hub.retryJob(job) } } }
                            Text(job.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if job.status == .running { ProgressView(value: Double(job.completed), total: Double(max(1, job.total))) }
                            if let result = job.result {
                                ForEach(result.outputs, id: \.self) { url in HStack { Text(url.lastPathComponent).font(.caption); Spacer(); Button("Preview") { QuickLookController.shared.show(url) }; Button("Save…") { saveCopy(url) } }.onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() } }
                                ForEach(Array(result.messages.enumerated()), id: \.offset) { _, text in Text(text).font(.caption).textSelection(.enabled) }
                            }
                        }.padding(14).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                    }
                    ForEach(hub.renames.sorted { $0.created > $1.created }) { record in
                        HStack { VStack(alignment: .leading) { Text("Batch rename · \(record.items.count) files").font(.headline); Text(record.error ?? record.status).font(.caption).foregroundStyle(.secondary) }; Spacer(); if record.status != "undone" { Button("Undo rename") { hub.undoRename(record) } } }.padding(14).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if hub.jobs.isEmpty && hub.renames.isEmpty { ContentUnavailableView("No activity yet", systemImage: "checklist") }
                }
            }
        }
    }
}

struct SummaryEvidenceView: View {
    let summary: String
    let seek: (Double) -> Void
    private var timestamps: [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\d{2}:\d{2}:\d{2}[.,]\d{3}"#) else { return [] }
        let values = regex.matches(in: summary, range: NSRange(summary.startIndex..., in: summary)).compactMap { match in Range(match.range, in: summary).map { String(summary[$0]) } }
        return Array(Set(values)).sorted()
    }
    var body: some View {
        if !timestamps.isEmpty {
            ScrollView(.horizontal) {
                HStack { Text("Evidence").font(.caption); ForEach(timestamps, id: \.self) { timestamp in Button(timestamp) { if let seconds = TranscriptExporter.seconds(timestamp) { seek(seconds) } }.font(.caption.monospaced()) } }
            }
        }
    }
}
