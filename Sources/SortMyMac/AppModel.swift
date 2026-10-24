import AppKit
import Combine
import SortMyMacCore

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let settings = SettingsStore()
    @Published var phase: SessionPhase = .idle
    @Published var groups: [FileGroup] = []
    @Published var progressCompleted = 0
    @Published var progressTotal = 0
    private var organizationTask: Task<Void, Never>?
    @Published var files: [FileDescriptor] = []
    @Published var warnings: [String] = []
    @Published var dropTargeted = false
    @Published var status = "Your next tidy moment starts here."
    @Published var expanded = false
    @Published var contentVisible = false
    @Published var geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1440, height: 900), safeTop: 0)
    var notch: NotchController?
    private var settingsWindow: SettingsWindow?

    var isBusy: Bool { phase == .analyzing || phase == .exporting || phase == .receiving }

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
        guard !isBusy else { return }
        let picker = NSOpenPanel()
        picker.title = "Bring files to SortMyMac"
        picker.message = "Choose up to 50 files to group by topic or project."
        picker.prompt = "Add files"
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        picker.begin { [weak self] response in
            if response == .OK { self?.receive(picker.urls) }
        }
    }

    func remove(_ id: UUID) {
        guard !isBusy else { return }
        groups = []
        files.removeAll { $0.id == id }
        warnings = []
        phase = files.isEmpty ? .idle : .ready
        status = files.isEmpty ? "Your next tidy moment starts here." : "\(files.count) files ready to organize."
    }

    func clear() {
        guard !isBusy else { return }
        groups = []
        files = []; warnings = []; phase = .idle
        status = "Your next tidy moment starts here."
    }

    func organize() {
        guard !isBusy, !files.isEmpty else { return }
        let credentials = CloudflareCredentials(accountID: settings.accountID.trimmingCharacters(in: .whitespacesAndNewlines),
                                                token: settings.token.trimmingCharacters(in: .whitespacesAndNewlines))
        do { try credentials.validate() }
        catch { warnings = [error.localizedDescription]; return }
        settings.saveToken()
        phase = .analyzing; warnings = []; groups = []
        progressCompleted = 0; progressTotal = 0
        let service = ClefGroupingService(client: ClefClient(credentials: credentials))
        let selected = files
        organizationTask = Task { [weak self] in
            do {
                let plan = try await service.group(selected) { [weak self] progress in
                    await self?.updateProgress(progress)
                }
                guard !Task.isCancelled, let self else { return }
                self.groups = plan.groups
                self.phase = .grouped
                self.status = "\(plan.groups.count) folders ready. Review, then drag them into Finder."
            } catch is CancellationError {
                guard let self else { return }
                self.groups = []; self.phase = .ready
                self.status = "Organization canceled. Your files are still in place."
            } catch {
                guard let self else { return }
                self.groups = []; self.phase = .failed
                self.warnings = [error.localizedDescription]
                self.status = "Couldn’t finish grouping. Your files are still in place."
            }
            self?.organizationTask = nil
        }
    }

    private func updateProgress(_ progress: GroupingProgress) {
        guard phase == .analyzing else { return }
        status = progress.message
        progressCompleted = progress.completed; progressTotal = progress.total
        if let plan = progress.plan { groups = plan.groups }
    }

    func cancelOrganization() { organizationTask?.cancel() }

    func showSettings() {
        notch?.collapse(force: true)
        if settingsWindow == nil { settingsWindow = SettingsWindow(model: self) }
        settingsWindow?.show()
    }
    func showNotch() { notch?.expand(immediate: true, keyboard: true) }
}
