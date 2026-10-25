import AppKit
import Combine
import BetterNotchCore

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let settings = SettingsStore()
    let hub = HubModel()
    #if DEBUG
    var pinOpenForSmokeTest = false
    var fixtureGroupingService: (any GroupingService)?
    #endif
    var moves = MoveCoordinator(journalURL: MoveCoordinator.defaultJournalURL)
    var organizationCoordinator = OrganizationCoordinator()
    @Published var organizationSession: OrganizationSession?
    @Published var organizationSessions: [OrganizationSession] = []
    var organizationStageTask: Task<Void, Never>?
    var organizationDraftTask: Task<Void, Never>?
    var organizationRevision = UUID()
    @Published var moveRecords: [MoveRecord] = []
    @Published var settingsPage = "Welcome"
    var activeDragSource: (NSView & NSDraggingSource)?
    var activePromises: [FolderPromise] = []
    var pendingExports: Set<UUID> = []
    var exportStarted: Set<UUID> = []
    var exportFailures: [String] = []
    var exportMovedCount = 0
    var exportCopiedCount = 0
    var exportSessionID: UUID?
    var exportWatchdog: Task<Void, Never>?
    @Published var phase: SessionPhase = .idle
    @Published var groups: [FileGroup] = []
    @Published var progressCompleted = 0
    @Published var progressTotal = 0
    var organizationTask: Task<Void, Never>?
    @Published var files: [FileDescriptor] = []
    @Published var warnings: [String] = []
    @Published var dropTargeted = false
    @Published var dropChoice: FileDropDestination?
    @Published var dragFileCount = 0
    var dropFrames: [FileDropDestination: CGRect] = [:]
    var canOrganizeDrop: Bool { !isBusy && !hasPendingOrganization && dragFileCount <= FileIntake.limit }
    @Published var status = "Your next tidy moment starts here."
    @Published var expanded = false
    @Published var contentVisible = false
    @Published var geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1440, height: 900), safeTop: 0)
    var notch: NotchController?
    private var settingsWindow: SettingsWindow?

    var isBusy: Bool { phase == .analyzing || phase == .exporting || phase == .receiving }

    func dropDestination(at point: CGPoint) -> FileDropDestination? {
        FileDropDestination.allCases.first { destination in
            (destination == .shelf || canOrganizeDrop) && dropFrames[destination]?.contains(point) == true
        }
    }

    @discardableResult func acceptDrop(_ urls: [URL], to destination: FileDropDestination) -> Bool {
        switch destination {
        case .shelf: hub.receive(urls); return true
        case .organize: return receiveForOrganization(urls)
        }
    }

    /// Organization has its own session and never adds files to the shelf.
    @discardableResult func receiveForOrganization(_ urls: [URL]) -> Bool {
        guard !isBusy else { hub.error = "Finish the current organization first."; return false }
        guard !hasPendingOrganization else { hub.error = "Move the current folders out, or use Undo to return them before adding more files."; hub.route = .organize; return false }
        let result = FileIntake.inspect(urls)
        guard !result.files.isEmpty, result.warnings.isEmpty else {
            hub.error = result.warnings.first ?? "Choose local files to organize."
            return false
        }
        hub.error = ""
        hub.route = .organize
        moveIntoOrganization(result.files)
        notch?.expand(immediate: true)
        return true
    }

    func receive(_ urls: [URL]) {
        guard !isBusy else { return }
        groups = []
        phase = .receiving
        let result = FileIntake.inspect(urls, existing: files)
        files = result.files
        warnings = result.warnings
        phase = files.isEmpty ? .idle : .ready
        status = files.isEmpty ? "Add files from Finder to get started." : "\(files.count) files ready. Originals stay in place until you drop the folders."
        notch?.expand(immediate: true)
    }

    func chooseFiles() {
        guard !isBusy, !hasPendingOrganization else { hub.route = .organize; return }
        let picker = NSOpenPanel()
        picker.title = "Organize files"
        picker.message = "Move up to 50 files temporarily into Organize, then group them. Undo returns them to their original folders."
        picker.prompt = "Organize"
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        picker.begin { [weak self] response in
            if response == .OK { self?.receiveForOrganization(picker.urls) }
        }
    }

    func remove(_ id: UUID) {
        guard !isBusy, !hasPendingOrganization else { return }
        groups = []
        files.removeAll { $0.id == id }
        warnings = []
        phase = files.isEmpty ? .idle : .ready
        status = files.isEmpty ? "Your next tidy moment starts here." : "\(files.count) files ready to organize."
    }

    func clear() {
        guard !isBusy else { return }
        if hasPendingOrganization { undoOrganization(); return }
        groups = []
        files = []; warnings = []; phase = .idle
        status = "Your next tidy moment starts here."
    }

    func organize() {
        guard !isBusy, !files.isEmpty else { return }
        guard let sessionID = organizationSession?.id else { _ = receiveForOrganization(files.map(\.url)); return }
        let credentials = CloudflareCredentials(accountID: settings.accountID.trimmingCharacters(in: .whitespacesAndNewlines),
                                                token: settings.token.trimmingCharacters(in: .whitespacesAndNewlines))
        let service: any GroupingService
        #if DEBUG
        if let fixtureGroupingService {
            service = fixtureGroupingService
        } else {
            service = ClefGroupingService(client: ClefClient(credentials: credentials))
        }
        #else
        service = ClefGroupingService(client: ClefClient(credentials: credentials))
        #endif
        phase = .analyzing; warnings = []; groups = []
        progressCompleted = 0; progressTotal = 0
        let selected = files
        let revision = UUID(); organizationRevision = revision
        organizationTask = Task { [weak self] in
            do {
                let plan = try await service.group(selected) { [weak self] progress in
                    await self?.updateProgress(progress)
                }
                guard !Task.isCancelled, let self, self.organizationRevision == revision else { return }
                let saved = try await self.organizationCoordinator.saveGroups(plan.groups, sessionID: sessionID)
                guard !Task.isCancelled, self.organizationRevision == revision else { return }
                self.organizationSession = saved
                self.groups = plan.groups
                self.phase = .grouped
                self.status = "\(plan.groups.count) folders ready in Organize. Drag them anywhere to move; Undo returns the originals."
            } catch is CancellationError {
                guard let self, self.organizationRevision == revision else { return }
                self.groups = []; self.phase = .ready
                self.status = "Grouping paused. Files remain in Organize; use Undo to return them."
            } catch {
                guard let self, self.organizationRevision == revision else { return }
                self.groups = []; self.phase = .failed
                self.warnings = [error.localizedDescription]
                self.status = "Couldn’t finish grouping. Files are safe in Organize; use Retry or Undo."
            }
            if self?.organizationRevision == revision { self?.organizationTask = nil }
        }
    }

    private func updateProgress(_ progress: GroupingProgress) {
        guard phase == .analyzing else { return }
        status = progress.message
        progressCompleted = progress.completed; progressTotal = progress.total
        if let plan = progress.plan { groups = plan.groups }
    }

    func renameDraft(_ id: UUID, to name: String) {
        guard phase == .grouped, let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].name = String(name.prefix(80))
        persistOrganizationDraft()
    }
    func rename(_ id: UUID, to name: String) {
        guard phase == .grouped else { return }
        var plan = GroupingPlan(groups: groups)
        plan.rename(id, to: name); groups = plan.groups
        persistOrganizationDraft()
    }
    func reassign(_ fileID: UUID, to groupID: UUID) {
        guard phase == .grouped else { return }
        var plan = GroupingPlan(groups: groups)
        plan.reassign(fileID, to: groupID); groups = plan.groups
        persistOrganizationDraft()
    }
    func separate(_ fileID: UUID) {
        guard phase == .grouped else { return }
        var plan = GroupingPlan(groups: groups)
        plan.separate(fileID); groups = plan.groups
        persistOrganizationDraft()
    }

    func cancelOrganization() { organizationTask?.cancel() }

    func showSettings() {
        notch?.collapse(force: true)
        if settingsWindow == nil { settingsWindow = SettingsWindow(model: self) }
        settingsWindow?.show()
    }
    func showNotch() { notch?.expand(immediate: true, keyboard: true) }
}
