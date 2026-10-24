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
        if !model.settings.completedSetup { model.showSettings() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
