import AppKit
import SortMyMacCore

extension HubModel {
    func startRecording() {
        guard !recordingBusy, !isRecording, !loading, store != nil else { return }
        recordingBusy = true; error = ""; liveDraft = ""; elapsed = 0
        let meeting = MeetingRecord(title: meetingTitle, source: audioSource)
        meetings.insert(meeting, at: 0); activeMeetingID = meeting.id; selectedMeetingID = meeting.id; persistMeeting(meeting)
        Task {
            await persistenceTask?.value
            do {
                try await recorder.start(meeting: meeting, root: root, microphoneID: microphoneID)
                recordingBusy = false; route = .meetingDetail
            } catch {
                if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
                    let manifest = root.appendingPathComponent("Meetings/\(meeting.id.uuidString)/manifest.json")
                    if let data = try? Data(contentsOf: manifest), let chunks = try? JSONDecoder().decode([AudioChunk].self, from: data) {
                        meetings[index].chunks = chunks; meetings[index].duration = chunks.map { $0.start + $0.duration }.max() ?? 0
                    }
                    meetings[index].status = .failed; meetings[index].error = error.localizedDescription; persistMeeting(meetings[index])
                }
                activeMeetingID = nil; recordingBusy = false; self.error = error.localizedDescription
            }
        }
    }
    func pauseRecording() {
        guard !recordingBusy, let id = activeMeetingID else { return }
        Task {
            await recorder.togglePause(); recordingPaused = recorder.paused
            if let index = meetings.firstIndex(where: { $0.id == id }) { meetings[index].status = recordingPaused ? .paused : .recording; persistMeeting(meetings[index]) }
        }
    }
    func receivedChunk(_ chunk: AudioChunk) {
        guard let id = activeMeetingID, let index = meetings.firstIndex(where: { $0.id == id }), !meetings[index].chunks.contains(where: { $0.id == chunk.id }) else { return }
        meetings[index].chunks.append(chunk); meetings[index].duration = max(meetings[index].duration, chunk.start + chunk.duration)
        persistMeeting(meetings[index]); startTranscription()
    }
    func stopRecording(interrupted: Bool = false, message: String? = nil, id suppliedID: UUID? = nil) async {
        guard !recordingBusy, let id = suppliedID ?? activeMeetingID else { return }
        recordingBusy = true
        await recorder.stop()
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { recordingBusy = false; activeMeetingID = nil; return }
        let manifest = root.appendingPathComponent("Meetings/\(id.uuidString)/manifest.json")
        if let data = try? Data(contentsOf: manifest), let chunks = try? JSONDecoder().decode([AudioChunk].self, from: data) { meetings[index].chunks = chunks }
        meetings[index].duration = max(elapsed, meetings[index].chunks.map { $0.start + $0.duration }.max() ?? 0)
        meetings[index].status = .finalizing; persistMeeting(meetings[index])
        do {
            guard !meetings[index].chunks.isEmpty else { throw SortError.message("No audio was captured. Check the source meters and permissions.") }
            let snapshot = meetings[index]
            let audio = try await MeetingAudio.finalize(snapshot, root: root)
            guard let current = meetings.firstIndex(where: { $0.id == id }) else { return }
            meetings[current].audioURL = audio; meetings[current].status = interrupted ? .interrupted : .ready; meetings[current].error = message; persistMeeting(meetings[current])
        } catch {
            if let current = meetings.firstIndex(where: { $0.id == id }) { meetings[current].status = .interrupted; meetings[current].error = error.localizedDescription; persistMeeting(meetings[current]) }
            self.error = error.localizedDescription
        }
        activeMeetingID = nil; recordingBusy = false; recordingPaused = false; liveDraft = ""
        startTranscription(); runNextJob()
    }
    func openMeeting(_ meeting: MeetingRecord) { selectedMeetingID = meeting.id; route = .meetingDetail }
    func renameMeeting(_ id: UUID, title: String) {
        guard let index = meetings.firstIndex(where: { $0.id == id }), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        meetings[index].title = title; persistMeeting(meetings[index])
    }
    func editSegment(_ meetingID: UUID, segmentID: UUID, text: String) {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }), let segment = meetings[index].segments.firstIndex(where: { $0.id == segmentID }) else { return }
        meetings[index].segments[segment].text = text; meetings[index].segments[segment].edited = true; persistMeeting(meetings[index])
    }
    func startTranscription() {
        guard transcriptionTask == nil, installedModels.contains(speechModel) else { return }
        var candidate: (UUID, [AudioChunk], [AudioChunk])?
        let ordered = meetings.sorted { first, second in
            if first.id == activeMeetingID { return second.id != activeMeetingID }
            if second.id == activeMeetingID { return false }
            return first.created < second.created
        }
        for meeting in ordered where !transcriptionFailures.contains(meeting.id) {
            for source in [AudioSource.microphone, .system, .both] {
                let sourceChunks = meeting.chunks.filter { $0.source == source }.sorted { $0.start < $1.start }
                let remaining = sourceChunks.filter { !meeting.processedChunks.contains($0.id) }
                guard !remaining.isEmpty else { continue }
                if activeMeetingID == meeting.id, remaining.count < 3 { continue }
                let batch = Array(remaining.prefix(4))
                let firstStart = batch[0].start
                let overlap = sourceChunks.last { $0.start < firstStart && meeting.processedChunks.contains($0.id) }
                // Alternate sources by their oldest unprocessed audio, so a microphone backlog cannot starve system audio.
                if candidate == nil || firstStart < candidate!.2[0].start {
                    candidate = (meeting.id, overlap.map { [$0] + batch } ?? batch, batch)
                }
            }
            if candidate != nil { break }
        }
        guard let (id, window, fresh) = candidate else { return }
        transcribingMeeting = id
        if let index = meetings.firstIndex(where: { $0.id == id }) { meetings[index].transcriptStatus = "Transcribing locally…"; persistMeeting(meetings[index]) }
        let modelID = speechModel, language = language
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let model = await speechModels.installed(modelID) else { throw SortError.message("Download a speech model to transcribe.") }
                let output = try await transcription.transcribe(window, model: model, language: language) { [weak self] text in Task { @MainActor in self?.liveDraft = text } }
                guard let index = meetings.firstIndex(where: { $0.id == id }) else { transcriptionTask = nil; transcribingMeeting = nil; return }
                let boundary = fresh[0].start
                for var segment in output where segment.end > boundary + 0.05 {
                    let previous = meetings[index].segments.last { $0.source == segment.source }?.text ?? ""
                    segment.text = TranscriptExporter.deduplicated(segment.text, previous: previous)
                    segment.start = max(boundary, segment.start)
                    segment.end = min(segment.end, fresh.last.map { $0.start + $0.duration } ?? segment.end)
                    let editedOverlap = meetings[index].segments.contains { $0.edited && $0.source == segment.source && $0.start < segment.end && $0.end > segment.start }
                    if !editedOverlap, !segment.text.isEmpty, segment.end > segment.start { meetings[index].segments.append(segment) }
                }
                meetings[index].processedChunks += fresh.map(\.id)
                let pending = meetings[index].chunks.filter { !meetings[index].processedChunks.contains($0.id) }
                meetings[index].transcriptStatus = pending.isEmpty ? (activeMeetingID == id ? "Live · up to date" : "Final transcript") : "Catching up · \(Int(pending.reduce(0) { $0 + $1.duration }))s of audio pending"
                if pending.isEmpty, activeMeetingID != id { meetings[index].revisions.append(TranscriptRevision(segments: meetings[index].segments)) }
                persistMeeting(meetings[index])
            } catch {
                transcriptionFailures.insert(id)
                if let index = meetings.firstIndex(where: { $0.id == id }) { meetings[index].transcriptStatus = error.localizedDescription; persistMeeting(meetings[index]) }
            }
            liveDraft = ""; transcribingMeeting = nil; transcriptionTask = nil; startTranscription(); runNextJob()
        }
    }
    func retryTranscript(_ meeting: MeetingRecord, redo: Bool = false) {
        guard transcribingMeeting != meeting.id, let index = meetings.firstIndex(where: { $0.id == meeting.id }) else { return }
        transcriptionFailures.remove(meeting.id)
        if redo {
            meetings[index].revisions.append(TranscriptRevision(segments: meetings[index].segments))
            meetings[index].segments.removeAll { !$0.edited }; meetings[index].processedChunks = []
        }
        persistMeeting(meetings[index]); startTranscription()
    }
    func importMeetings() {
        let inputs = editorInputs
        route = .meetings
        for file in inputs {
            var meeting = MeetingRecord(title: file.url.deletingPathExtension().lastPathComponent, source: .both)
            meeting.status = .finalizing; meeting.transcriptStatus = "Importing audio…"
            let id = meeting.id; meetings.insert(meeting, at: 0); persistMeeting(meeting)
            Task {
                do {
                    let chunks = try await MeetingAudio.importFile(file, meetingID: id, root: root)
                    guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
                    meetings[index].chunks = chunks; meetings[index].duration = chunks.reduce(0) { $0 + $1.duration }
                    let audio = try await MeetingAudio.finalize(meetings[index], root: root)
                    guard let current = meetings.firstIndex(where: { $0.id == id }) else { return }
                    meetings[current].audioURL = audio; meetings[current].status = .ready; meetings[current].transcriptStatus = "Waiting for local transcription"; persistMeeting(meetings[current]); startTranscription()
                } catch {
                    if let index = meetings.firstIndex(where: { $0.id == id }) { meetings[index].status = .interrupted; meetings[index].error = error.localizedDescription; persistMeeting(meetings[index]) }
                }
            }
        }
    }
    func recoverAudio(_ meeting: MeetingRecord) {
        Task {
            do {
                let audio = try await MeetingAudio.finalize(meeting, root: root)
                if let index = meetings.firstIndex(where: { $0.id == meeting.id }) { meetings[index].audioURL = audio; meetings[index].status = .ready; persistMeeting(meetings[index]) }
            } catch { self.error = error.localizedDescription }
        }
    }
    func exportTranscript(_ meeting: MeetingRecord, format: String) {
        do {
            let id = UUID(), folder = try UtilityPaths.directory("Outputs/\(id.uuidString)", root: root)
            let name = FolderNames.safeComponent(meeting.title)
            let url = folder.appendingPathComponent(name + "." + format)
            try Data(TranscriptExporter.text(meeting, format: format).utf8).write(to: url, options: .withoutOverwriting)
            add([url], managed: true); route = .results
        } catch { self.error = error.localizedDescription }
    }
    func editSummary(_ id: UUID, text: String) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].summary = text; persistMeeting(meetings[index])
    }
    func cancelTranscription(_ meeting: MeetingRecord) {
        transcriptionFailures.insert(meeting.id)
        if transcribingMeeting == meeting.id { transcriptionTask?.cancel() }
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) { meetings[index].transcriptStatus = "Transcription canceled. Audio is preserved."; persistMeeting(meetings[index]) }
    }
    func summarizeMeeting(_ meeting: MeetingRecord) {
        guard !meeting.segments.isEmpty else { error = "Transcribe the meeting first."; return }
        Task {
            do {
                let value = try await summary.summarize(text: TranscriptExporter.text(meeting, format: "md"), model: ollamaModel, endpoint: ollamaEndpoint)
                if let index = meetings.firstIndex(where: { $0.id == meeting.id }) { meetings[index].summary = value; persistMeeting(meetings[index]) }
            } catch { self.error = error.localizedDescription }
        }
    }
    func deleteMeeting(_ meeting: MeetingRecord) {
        guard activeMeetingID != meeting.id, transcribingMeeting != meeting.id, meeting.status != .finalizing else { error = "Stop recording or wait for processing before deleting this meeting."; return }
        do {
            let folder = root.appendingPathComponent("Meetings/\(meeting.id.uuidString)")
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.trashItem(at: folder, resultingItemURL: nil) }
            meetings.removeAll { $0.id == meeting.id }; removeStored("meetings", meeting.id); route = .meetings
        } catch { self.error = error.localizedDescription }
    }
}
