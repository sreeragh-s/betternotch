import AppKit
import Combine
import BetterNotchCore
import UniformTypeIdentifiers

@MainActor
final class HubModel: ObservableObject {
    weak var owner: AppModel?
    @Published var route: NotchRoute = .home { didSet {
        if route == .results { selection.formIntersection(Set(shelf.filter(\.managed).map(\.id))) }
        owner?.notch?.resizeForContent()
    } }
    @Published var shelf: [ShelfItem] = []
    @Published var jobs: [JobRecord] = []
    @Published var meetings: [MeetingRecord] = []
    @Published var pins: [DestinationPin] = []
    @Published var presets: [ActionPreset] = []
    @Published var renames: [RenameRecord] = []
    @Published var selection = Set<UUID>()
    @Published var actionItems = Set<UUID>()
    @Published var pendingPreset: ActionPreset?
    @Published var editorKind: FileActionKind?
    @Published var editorInputs: [FileDescriptor] = []
    @Published var settings = ActionSettings()
    @Published var previewResult: ActionResult?
    @Published var previewBusy = false
    @Published var error = ""
    @Published var loading = true
    @Published var activeMeetingID: UUID?
    @Published var selectedMeetingID: UUID?
    @Published var elapsed = 0.0
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published var recordingPaused = false
    @Published var recordingBusy = false
    @Published var liveDraft = ""
    @Published var speechModel = UserDefaults.standard.string(forKey: "speechModel") ?? "small"
    @Published var language = UserDefaults.standard.string(forKey: "speechLanguage") ?? "auto"
    @Published var installedModels: Set<String> = []
    @Published var downloadProgress: Double?
    @Published var meetingTitle = ""
    @Published var audioSource: AudioSource = .both
    @Published var microphoneID: UInt32 = 0
    @Published var ollamaEndpoint = UserDefaults.standard.string(forKey: "ollamaEndpoint") ?? "http://localhost:11434"
    @Published var ollamaModel = UserDefaults.standard.string(forKey: "ollamaModel") ?? ""
    @Published var shortcutName = UserDefaults.standard.string(forKey: "shortcutName") ?? ""
    let recorder = MeetingRecorder()
    let codex: CodexModel = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--smoke-test"), args.indices.contains(i + 1) {
            let suite = UserDefaults(suiteName: "BetterNotch-QA-" + UUID().uuidString)!
            let root = URL(fileURLWithPath: args[i + 1]).appendingPathComponent("CodexInbox")
            let store = CodexBridgeStore(root: root)
            return CodexModel(defaults: suite, store: store, hooksURL: root.appendingPathComponent("hooks.json"), sessionsRoot: root.appendingPathComponent("sessions"), replySender: { event, _ in
                try store.publish(CodexEvent(kind: .resolved, threadID: event.threadID, title: "UI test answer received", resolvesID: event.id))
            })
        }
        #endif
        return CodexModel()
    }()
    var root = UtilityPaths.root
    var store: LibraryStore?
    var executor = ActionExecutor()
    var previewExecutor = ActionExecutor(root: UtilityPaths.root.appendingPathComponent("Cache/Previews"))
    var previewRoot: URL { root.appendingPathComponent("Cache/Previews") }
    var speechModels = SpeechModels()
    let transcription = LocalTranscription(), summary = LocalSummary()
    var renameCoordinator: RenameCoordinator?
    var jobTask: Task<Void, Never>?
    var previewTask: Task<Void, Never>?
    var transcriptionTask: Task<Void, Never>?
    var downloadTask: Task<Void, Never>?
    var persistenceTask: Task<Void, Never>?
    var previewRevision = UUID()
    var transcribingMeeting: UUID?
    var transcriptionFailures = Set<UUID>()
    var acceptedResultIDs = Set<UUID>()
    var drafts: [String: ActionSettings] = [:]
    var pendingAdds: [(URL, Bool)] = []
    var isRecording: Bool { activeMeetingID != nil }
    var selectedFiles: [FileDescriptor] {
        shelf.filter { selection.contains($0.id) }.compactMap { item in
            guard let url = item.resolvedURL(), let current = try? FileIntake.describe(url) else { return nil }
            return FileDescriptor(id: item.file.id, url: current.url, size: current.size, modified: current.modified, typeIdentifier: current.typeIdentifier, identity: current.identity)
        }
    }
    var activeMeeting: MeetingRecord? { meetings.first { $0.id == activeMeetingID } }
    var selectedMeeting: MeetingRecord? { meetings.first { $0.id == selectedMeetingID } }
    var currentJobs: [JobRecord] { jobs.filter { [.running, .queued].contains($0.status) } }
    var editing: Bool { route == .editor || route == .meetingDetail || route == .recordingSetup || route == .models || route == .codex || route == .codexDiff }

    func start(owner: AppModel, root: URL? = nil) async {
        self.owner = owner
        codex.onPendingChanged = { [weak self] in self?.codexPromptsChanged() }
        codex.onHandoff = { [weak self] in self?.owner?.notch?.collapse(force: true) }
        if root == nil { codex.start() }
        if let root { self.root = root }
        executor = ActionExecutor(root: self.root); previewExecutor = ActionExecutor(root: previewRoot); speechModels = SpeechModels(root: self.root)
        // Only disposable previews are cleaned. Kept outputs and meetings live outside this directory.
        let cache = previewRoot
        await Task.detached { try? FileManager.default.removeItem(at: cache) }.value
        do {
            let store = try LibraryStore(url: self.root.appendingPathComponent("library.sqlite")); self.store = store
            renameCoordinator = RenameCoordinator(store: store)
            shelf = try await store.list(ShelfItem.self, category: "shelf")
            jobs = try await store.list(JobRecord.self, category: "jobs")
            meetings = try await store.list(MeetingRecord.self, category: "meetings")
            pins = try await store.list(DestinationPin.self, category: "pins")
            presets = try await store.list(ActionPreset.self, category: "presets")
            renames = try await store.list(RenameRecord.self, category: "renames")
            for index in jobs.indices where [.running, .queued].contains(jobs[index].status) {
                jobs[index].status = .interrupted; jobs[index].message = "Interrupted. Retry to create a fresh output."; persist(jobs[index], "jobs", jobs[index].id)
            }
            for index in meetings.indices where [.recording, .paused, .finalizing].contains(meetings[index].status) {
                let manifest = self.root.appendingPathComponent("Meetings/\(meetings[index].id.uuidString)/manifest.json")
                if let data = try? Data(contentsOf: manifest), let chunks = try? JSONDecoder().decode([AudioChunk].self, from: data) { meetings[index].chunks = chunks }
                meetings[index].status = .interrupted
                meetings[index].error = "Recording was interrupted. Completed audio chunks were recovered; the unfinished chunk may be missing."
                meetings[index].duration = meetings[index].chunks.map { $0.start + $0.duration }.max() ?? 0
                persistMeeting(meetings[index])
            }
            for model in SpeechModel.choices { if await speechModels.installed(model.id) != nil { installedModels.insert(model.id) } }
        } catch { self.error = error.localizedDescription }
        loading = false
        await owner.configureOrganizationStorage(root: self.root)
        let pending = pendingAdds; pendingAdds = []
        for (url, managed) in pending { add([url], managed: managed) }
        if route == .fileActions { actionItems = selection }
        recorder.onChunk = { [weak self] chunk in self?.receivedChunk(chunk) }
        recorder.onError = { [weak self] error in
            guard let self, let id = self.activeMeetingID else { return }
            self.error = error
            Task { await self.stopRecording(interrupted: true, message: error, id: id) }
        }
        recorder.onMeter = { [weak self] mic, system, elapsed in self?.micLevel = mic; self?.systemLevel = system; self?.elapsed = elapsed }
    }
    private func codexPromptsChanged() {
        guard let owner else { return }
        owner.notch?.resizeForContent()
        if codex.visible.isEmpty {
            if route == .codex || route == .codexDiff { owner.notch?.collapse(force: true); route = .home }
            return
        }
        // Alert without stealing focus or interrupting a file editor, recording setup, or drag.
        guard !route.isLarge, route != .recordingSetup, !owner.dropTargeted, owner.activeDragSource == nil else { return }
        if codex.selected == nil { codex.selectedID = codex.visible.first?.id }
        route = .codex
        owner.notch?.expand(immediate: true, keyboard: false)
    }
    func persist<T: Encodable & Sendable>(_ value: T, _ category: String, _ id: UUID) {
        guard let store else { return }
        let previous = persistenceTask
        persistenceTask = Task { [weak self] in
            await previous?.value
            do { try await store.save(value, category: category, id: id.uuidString) } catch { self?.error = error.localizedDescription }
        }
    }
    func removeStored(_ category: String, _ id: UUID) {
        guard let store else { return }; let previous = persistenceTask
        persistenceTask = Task { [weak self] in await previous?.value; do { try await store.remove(category: category, id: id.uuidString) } catch { self?.error = error.localizedDescription } }
    }
    func persistMeeting(_ meeting: MeetingRecord) { persist(meeting, "meetings", meeting.id) }
    func add(_ urls: [URL], managed: Bool = false) {
        if loading { pendingAdds += urls.map { ($0, managed) }; return }
        for url in urls {
            do {
                let file: FileDescriptor
                if managed, let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]), values.isDirectory == true, values.isSymbolicLink != true {
                    file = FileDescriptor(url: url, size: 0, modified: values.contentModificationDate ?? Date(), typeIdentifier: UTType.folder.identifier, identity: try LocalFileOperations().stamp(url).identity)
                } else { file = try FileIntake.describe(url) }
                if let existing = shelf.first(where: { $0.resolvedURL()?.standardizedFileURL == url.standardizedFileURL }) { selection.insert(existing.id); continue }
                let item = ShelfItem(file: file, managed: managed); shelf.append(item); selection.insert(item.id); persist(item, "shelf", item.id)
            } catch { self.error = error.localizedDescription }
        }
    }
    func receive(_ urls: [URL]) { selection = []; add(urls); actionItems = selection; route = .shelf }
    func chooseFiles() {
        owner?.notch?.focusForEditing()
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; panel.message = "Choose files to keep on the shelf and use with file tools."
        panel.begin { [weak self] result in if result == .OK { self?.receive(panel.urls) } }
    }
    func removeShelf(_ item: ShelfItem) { shelf.removeAll { $0.id == item.id }; selection.remove(item.id); removeStored("shelf", item.id) }
    func locate(_ item: ShelfItem) {
        let panel = NSOpenPanel(); panel.message = "Locate \(item.file.name)"; panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            self.removeShelf(item); self.add([url], managed: false)
        }
    }
    func deleteManaged(_ item: ShelfItem) {
        guard item.managed, item.file.url.standardizedFileURL.path.hasPrefix(root.appendingPathComponent("Outputs").path + "/") else { return }
        do { try FileManager.default.trashItem(at: item.file.url, resultingItemURL: nil); removeShelf(item) } catch { self.error = error.localizedDescription }
    }
    func open(_ definition: FileActionDefinition) {
        error = ""
        if definition.kind == .organize {
            error = "Use the separate Organize drop target or Home → Organize."
            return
        }
        actionItems = Set(definition.inputs.map(\.id))
        pendingPreset = nil
        editorKind = definition.kind; editorInputs = definition.inputs
        let key = draftKey(definition.kind, definition.inputs)
        var settings = drafts[key] ?? ActionSettings()
        if drafts[key] == nil {
            switch definition.kind {
            case .trim, .convertMedia: settings.format = UTType(definition.inputs[0].typeIdentifier)?.conforms(to: .audio) == true ? "m4a" : "mp4"
            case .compressVideo: settings.format = "mp4"
            case .extractAudio: settings.format = "m4a"
            case .removeBackground: settings.format = "png"
            case .cropImage, .resize:
                let ext = definition.inputs[0].url.pathExtension.lowercased()
                let format = ["jpg": "jpeg", "jpeg": "jpeg", "png": "png", "heic": "heic", "tif": "tiff", "tiff": "tiff", "webp": "webp"][ext] ?? "png"
                settings.format = ImageProcessor.outputFormats.contains(format) ? format : "png"
            case .transcribe: settings.language = language
            case .shortcut: settings.shortcut = shortcutName
            default: break
            }
        }
        self.settings = settings; discardPreview(); route = .editor
    }
    func draftKey(_ kind: FileActionKind, _ inputs: [FileDescriptor]) -> String { kind.rawValue + inputs.map(\.id.uuidString).joined() }
    func settingsChanged() {
        guard let kind = editorKind else { return }
        drafts[draftKey(kind, editorInputs)] = settings
        discardPreview()
    }
    func discardPreview() {
        previewRevision = UUID(); previewTask?.cancel(); previewTask = nil; previewBusy = false
        if let result = previewResult, !acceptedResultIDs.contains(result.id) {
            let directory = previewRoot.appendingPathComponent("Outputs/\(result.id.uuidString)")
            Task.detached { try? FileManager.default.removeItem(at: directory) }
        }
        previewResult = nil
    }
    func generatePreview() {
        guard let kind = editorKind, !previewBusy else { return }
        discardPreview(); let revision = previewRevision
        let request = ActionRequest(kind: kind, inputs: editorInputs, settings: settings)
        let pipeline = pendingPreset.map { preset in preset.steps.enumerated().map { index, step in ActionRequest(kind: step.kind, inputs: [], settings: index == 0 ? settings : step.settings) } }
        previewBusy = true; error = ""
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result: ActionResult
                if let pipeline { result = try await previewExecutor.executePipeline(id: request.id, steps: pipeline, inputs: request.inputs) { _, _, _ in } }
                else { result = try await previewExecutor.execute(request) { _, _, _ in } }
                guard revision == previewRevision, !Task.isCancelled else { try? FileManager.default.removeItem(at: previewRoot.appendingPathComponent("Outputs/\(result.id.uuidString)")); return }
                previewResult = result; previewBusy = false
            } catch { if revision == previewRevision { self.error = error.localizedDescription; previewBusy = false } }
        }
    }
    func keepPreview() {
        guard var result = previewResult, let kind = editorKind else { return }
        if !result.outputs.isEmpty, !acceptedResultIDs.contains(result.id) {
            do {
                let parent = try UtilityPaths.directory("Outputs", root: root)
                let destination = parent.appendingPathComponent(result.id.uuidString)
                try FileManager.default.moveItem(at: previewRoot.appendingPathComponent("Outputs/\(result.id.uuidString)"), to: destination)
                result.outputs = result.outputs.map { destination.appendingPathComponent($0.lastPathComponent) }
                previewResult = result
            } catch { self.error = error.localizedDescription; return }
        }
        acceptedResultIDs.insert(result.id); selection = []; add(result.outputs, managed: true)
        var job = JobRecord(request: ActionRequest(id: result.id, kind: kind, inputs: editorInputs, settings: settings))
        job.status = .completed; job.result = result; job.completed = job.total; job.message = "Completed"
        jobs.insert(job, at: 0); persist(job, "jobs", job.id); route = kind == .duplicates ? .jobs : .results
    }
    func enqueue() {
        guard let kind = editorKind else { return }
        if kind == .transcribe { importMeetings(); return }
        if kind == .rename { applyRename(); return }
        if kind == .summarize { summarizeFiles(); return }
        var job = JobRecord(request: ActionRequest(kind: kind, inputs: editorInputs, settings: settings))
        job.presetSteps = pendingPreset?.steps.enumerated().map { index, step in ActionRequest(kind: step.kind, inputs: [], settings: index == 0 ? settings : step.settings) }
        if isRecording { job.message = "Waiting until recording stops" }
        jobs.insert(job, at: 0); persist(job, "jobs", job.id); route = .jobs; runNextJob()
    }
    func runNextJob() {
        guard jobTask == nil, !isRecording, transcribingMeeting == nil, let next = jobs.last(where: { $0.status == .queued }) else { return }
        updateJob(next.id) { $0.status = .running; $0.message = "Starting…" }
        jobTask = Task { [weak self] in
            guard let self else { return }
            do {
                let progress: @Sendable (Int, Int, String) async -> Void = { [weak self] completed, total, message in
                    await self?.updateJob(next.id) { $0.completed = completed; $0.total = total; $0.message = message }
                }
                let result: ActionResult
                if let steps = next.presetSteps { result = try await executor.executePipeline(id: next.id, steps: steps, inputs: next.request.inputs, progress: progress) }
                else { result = try await executor.execute(next.request, progress: progress) }
                add(result.outputs, managed: true)
                updateJob(next.id) { $0.status = .completed; $0.result = result; $0.message = "Completed"; $0.completed = $0.total }
            } catch is CancellationError { updateJob(next.id) { $0.status = .canceled; $0.message = "Canceled" } }
            catch { updateJob(next.id) { $0.status = .failed; $0.message = error.localizedDescription } }
            jobTask = nil; runNextJob()
        }
    }
    func updateJob(_ id: UUID, change: (inout JobRecord) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }; change(&jobs[index]); persist(jobs[index], "jobs", id)
    }
    func cancelJob(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        if job.status == .running { jobTask?.cancel() } else if job.status == .queued { updateJob(id) { $0.status = .canceled; $0.message = "Canceled" } }
    }
    func retryJob(_ job: JobRecord) { var new = JobRecord(request: ActionRequest(kind: job.request.kind, inputs: job.request.inputs, settings: job.request.settings)); new.presetSteps = job.presetSteps; jobs.insert(new, at: 0); persist(new, "jobs", new.id); runNextJob() }
    func pinDestination() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.begin { [weak self] result in guard result == .OK, let url = panel.url, let self else { return }; do { let pin = try DestinationPin(url: url); pins.append(pin); persist(pin, "pins", pin.id) } catch { self.error = error.localizedDescription } }
    }
    func transfer(_ pin: DestinationPin, moving: Bool) {
        let files = selectedFiles
        guard !files.isEmpty, let owner, !owner.isBusy else { return }
        let previousPhase = owner.phase
        if moving { owner.phase = .exporting }
        Task {
            defer { if moving { owner.phase = previousPhase } }
            do {
                let destination = try pin.resolve()
                if moving { _ = try await owner.moves.export(FileGroup(name: "Files", files: files), into: destination) }
                else {
                    _ = try await Task.detached { try DestinationCopy.copy(files, into: destination) }.value
                }
                if moving { for item in shelf.filter({ files.map(\.id).contains($0.file.id) }) { removeShelf(item) } }
                await owner.refreshHistory()
            } catch { self.error = error.localizedDescription }
        }
    }
    func applyRename() {
        guard let coordinator = renameCoordinator else { return }
        let inputs = editorInputs, snapshot = settings
        Task {
            do {
                let record = try await coordinator.apply(inputs, settings: snapshot)
                renames.insert(record, at: 0)
                for item in record.items {
                    if let shelfItem = shelf.first(where: { $0.file.url == item.source.url }) { removeShelf(shelfItem) }
                    add([item.destination])
                }
                route = .jobs
            } catch { self.error = error.localizedDescription; if let store { renames = (try? await store.list(RenameRecord.self, category: "renames")) ?? renames } }
        }
    }
    func undoRename(_ record: RenameRecord) {
        guard let coordinator = renameCoordinator else { return }
        Task { do {
            let result = try await coordinator.undo(record)
            if let index = renames.firstIndex(where: { $0.id == result.id }) { renames[index] = result }
            for item in result.items { add([item.source.url]) }
        } catch { self.error = error.localizedDescription } }
    }
    func savePreset(name: String) {
        guard let kind = editorKind else { return }
        let step = ActionRequest(kind: kind, inputs: [], settings: settings)
        let preset = ActionPreset(name: name.isEmpty ? kind.title : name, steps: [step])
        presets.append(preset); persist(preset, "presets", preset.id)
    }
    func appendPresetStep(_ preset: ActionPreset) {
        guard let kind = editorKind, let index = presets.firstIndex(where: { $0.id == preset.id }), preset.steps.count < 12 else { return }
        guard ![FileActionKind.organize, .rename, .transcribe, .summarize, .duplicates].contains(kind), !preset.steps.contains(where: { [.organize, .rename, .transcribe, .summarize, .duplicates].contains($0.kind) }) else { error = "Only file transformation steps can be chained."; return }
        presets[index].steps.append(ActionRequest(kind: kind, inputs: [], settings: settings)); persist(presets[index], "presets", preset.id)
    }
    func applyPreset(_ preset: ActionPreset) {
        guard let first = preset.steps.first else { return }
        let definitions = FileActionDefinition.available(for: selectedFiles)
        guard let definition = definitions.first(where: { $0.kind == first.kind }) else { error = "Select files compatible with this preset."; return }
        open(definition); settings = first.settings
        if preset.steps.count > 1 { pendingPreset = preset }
    }
    func saveLocalSettings() {
        UserDefaults.standard.set(ollamaEndpoint, forKey: "ollamaEndpoint"); UserDefaults.standard.set(ollamaModel, forKey: "ollamaModel"); UserDefaults.standard.set(shortcutName, forKey: "shortcutName")
        UserDefaults.standard.set(speechModel, forKey: "speechModel"); UserDefaults.standard.set(language, forKey: "speechLanguage")
    }
    func downloadModel(_ model: SpeechModel) {
        guard downloadTask == nil else { return }
        downloadProgress = 0
        downloadTask = Task {
            do {
                _ = try await speechModels.install(model.id) { [weak hub = self] value in Task { @MainActor in hub?.downloadProgress = value } }
                installedModels.insert(model.id); speechModel = model.id; saveLocalSettings(); startTranscription()
            } catch { self.error = error.localizedDescription }
            downloadTask = nil; downloadProgress = nil
        }
    }
    func removeModel(_ id: String) {
        guard transcribingMeeting == nil, !isRecording else { error = "Stop recording and transcription before removing a speech model."; return }
        Task { await transcription.unload(); do { try await speechModels.remove(id); installedModels.remove(id) } catch { self.error = error.localizedDescription } }
    }
    func summarizeFiles() {
        let files = editorInputs
        discardPreview(); let revision = previewRevision
        previewBusy = true
        previewTask = Task {
            do {
                let text = try await Task.detached { try files.map { try PDFProcessor.extractedText($0) }.joined(separator: "\n\n") }.value
                let value = try await summary.summarize(text: text, model: ollamaModel, endpoint: ollamaEndpoint)
                try Task.checkCancellation()
                guard revision == previewRevision else { return }
                let id = UUID(), directory = try UtilityPaths.directory("Outputs/\(id.uuidString)", root: previewRoot)
                let output = directory.appendingPathComponent("Summary.txt"); try Data(value.utf8).write(to: output)
                previewResult = ActionResult(id: id, outputs: [output]); previewBusy = false
            } catch { if revision == previewRevision { self.error = error.localizedDescription; previewBusy = false } }
        }
    }
}
