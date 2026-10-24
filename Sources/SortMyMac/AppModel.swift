import AppKit
import Combine
import SortMyMacCore

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let settings = SettingsStore()
    @Published var phase: SessionPhase = .idle
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
        files.removeAll { $0.id == id }
        warnings = []
        phase = files.isEmpty ? .idle : .ready
        status = files.isEmpty ? "Your next tidy moment starts here." : "\(files.count) files ready to organize."
    }

    func clear() {
        guard !isBusy else { return }
        files = []; warnings = []; phase = .idle
        status = "Your next tidy moment starts here."
    }

    func organize() {
        status = "Connect Cloudflare in Settings to organize these files."
        showSettings()
    }

    func showSettings() {
        notch?.collapse(force: true)
        if settingsWindow == nil { settingsWindow = SettingsWindow(model: self) }
        settingsWindow?.show()
    }
    func showNotch() { notch?.expand(immediate: true, keyboard: true) }
}
