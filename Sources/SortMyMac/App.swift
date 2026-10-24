import AppKit
import SwiftUI

@main
struct SortMyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            Button("Open SortMyMac") { model.showNotch() }.keyboardShortcut("o")
            Button("Add files…") { model.hub.chooseFiles() }.keyboardShortcut("a")
            Button(model.hub.isRecording ? "Show active meeting" : "Record meeting…") {
                model.hub.selectedMeetingID = model.hub.activeMeetingID
                model.hub.route = model.hub.isRecording ? .meetingDetail : .recordingSetup
                model.showNotch()
            }
            Button("Meetings") { model.hub.route = .meetings; model.showNotch() }
            Button("Codex") { model.hub.route = .codex; model.showNotch() }
            Button("Settings…") { model.showSettings() }.keyboardShortcut(",")
            if model.phase == .grouped {
                Button("Move folders to…") { model.chooseExportDestination(model.groups) }.keyboardShortcut("m", modifiers: [.command, .shift])
            }
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
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--smoke-test"), arguments.indices.contains(flag + 1) {
            do { try SmokeTestSupport.configure(model, root: URL(fileURLWithPath: arguments[flag + 1]))
                Task {
                    let root = URL(fileURLWithPath: arguments[flag + 1])
                    await model.hub.start(owner: model, root: root.appendingPathComponent("library"))
                    model.hub.receive(model.files.map(\.url))
                    do { try await SmokeTestSupport.populateHub(model, root: root) } catch { model.hub.error = error.localizedDescription }
                } }
            catch { model.warnings = [error.localizedDescription]; model.showNotch() }
            return
        }
        #endif
        Task { await model.hub.start(owner: model); await model.refreshHistory() }
        if !model.settings.completedSetup || ProcessInfo.processInfo.arguments.contains("--show-settings") { model.showSettings() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppModel.shared.showNotch()
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        if model.phase == .exporting || model.hub.isRecording || model.hub.recordingBusy {
            model.status = "Stop and save the recording or finish the current move before quitting."
            model.hub.error = model.status
            model.showNotch()
            return .terminateCancel
        }
        model.hub.jobTask?.cancel()
        model.hub.previewTask?.cancel()
        model.hub.transcriptionTask?.cancel()
        model.hub.downloadTask?.cancel()
        model.hub.codex.stop()
        model.cancelOrganization()
        model.notch?.shutdown()
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
