import AppKit
import Combine
import SortMyMacCore

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let settings = SettingsStore()
    @Published var phase: SessionPhase = .idle
    @Published var status = "Your next tidy moment starts here."
    @Published var expanded = false
    @Published var contentVisible = false
    @Published var geometry = NotchGeometry(screen: CGRect(x: 0, y: 0, width: 1440, height: 900), safeTop: 0)
    var notch: NotchController?
    private var settingsWindow: SettingsWindow?

    func showSettings() {
        notch?.collapse(force: true)
        if settingsWindow == nil { settingsWindow = SettingsWindow(model: self) }
        settingsWindow?.show()
    }
    func showNotch() { notch?.expand(immediate: true, keyboard: true) }
}
