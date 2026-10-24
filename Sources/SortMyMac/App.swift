import AppKit
import SwiftUI

@main
struct SortMyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            Button("Open SortMyMac") { model.showNotch() }.keyboardShortcut("o")
            Button("Add files…") { model.chooseFiles() }.keyboardShortcut("a")
            Button("Settings…") { model.showSettings() }.keyboardShortcut(",")
            Button("Recovery & Undo…") { model.showRecovery() }
            Divider()
            Text(model.status)
            Divider()
            Button("Quit SortMyMac") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(systemName: "folder.badge.gearshape").accessibilityLabel("SortMyMac")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let model = AppModel.shared
        model.notch = NotchController(model: model)
        Task { await model.refreshHistory() }
        if !model.settings.completedSetup { model.showSettings() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        if model.phase == .exporting {
            model.status = "Finish the current move before quitting. Recovery is available if the app is interrupted."
            model.showNotch()
            return .terminateCancel
        }
        model.cancelOrganization()
        model.notch?.shutdown()
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
