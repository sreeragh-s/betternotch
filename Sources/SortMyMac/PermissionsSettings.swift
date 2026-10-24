import AppKit
@preconcurrency import AVFoundation
import CoreGraphics
import SwiftUI

enum PrivacyPane: String {
    case microphone = "Privacy_Microphone"
    case screenRecording = "Privacy_ScreenCapture"
    case filesAndFolders = "Privacy_FilesAndFolders"

    var url: URL { URL(string: "x-apple.systempreferences:com.apple.preference.security?" + rawValue)! }
}

@MainActor
struct PermissionAccess {
    var microphoneStatus: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) }
    var screenStatus: () -> Bool = { CGPreflightScreenCaptureAccess() }
    var requestMicrophone: () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }
    var requestScreen: () -> Bool = { CGRequestScreenCaptureAccess() }
    var openSettings: (PrivacyPane) -> Bool = { pane in
        NSWorkspace.shared.open(pane.url) || NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
    }
}

@MainActor
final class PermissionSettingsModel: ObservableObject {
    @Published private(set) var microphone: AVAuthorizationStatus = .notDetermined
    @Published private(set) var screenAllowed = false
    @Published private(set) var requestingMicrophone = false
    @Published private(set) var screenRequestIssued = false
    @Published private(set) var message = ""
    private let access: PermissionAccess
    private var guidanceFor: PrivacyPane?

    init(access: PermissionAccess = PermissionAccess()) { self.access = access; refresh() }

    /// Reading status never displays a permission dialog or starts capture.
    func refresh() {
        microphone = access.microphoneStatus(); screenAllowed = access.screenStatus()
        if (guidanceFor == .microphone && microphone == .authorized) || (guidanceFor == .screenRecording && screenAllowed) { message = ""; guidanceFor = nil }
    }

    func requestMicrophone() async {
        refresh()
        guard !requestingMicrophone, microphone != .authorized else { return }
        guard microphone == .notDetermined else { open(.microphone); return }
        requestingMicrophone = true
        _ = await access.requestMicrophone()
        requestingMicrophone = false; refresh()
        if microphone != .authorized { guidanceFor = .microphone; message = "Enable SortMyMac in System Settings → Privacy & Security → Microphone." }
    }

    func requestScreen() {
        refresh()
        guard !screenAllowed, !screenRequestIssued else { return }
        screenRequestIssued = true
        _ = access.requestScreen()
        refresh()
        if !screenAllowed {
            guidanceFor = .screenRecording
            message = "Enable SortMyMac in Privacy & Security → Screen & System Audio Recording. If macOS asks, quit and reopen the app, then refresh the status."
        }
    }

    func open(_ pane: PrivacyPane) {
        if !access.openSettings(pane) { message = "Open System Settings → Privacy & Security to manage this permission." }
    }

    var microphoneLabel: String {
        switch microphone {
        case .authorized: "Allowed"
        case .notDetermined: "Not requested"
        case .denied: "Not allowed"
        case .restricted: "Restricted"
        @unknown default: "Check settings"
        }
    }
}

struct PermissionsSettingsView: View {
    @StateObject private var permissions = PermissionSettingsModel()
    var body: some View {
        Form {
            Section("Meeting recording") {
                VStack(alignment: .leading, spacing: 12) {
                    permissionHeading("Microphone", symbol: "mic.fill", description: "Capture your voice during meetings.", status: permissions.microphoneLabel, allowed: permissions.microphone == .authorized)
                    HStack {
                        Spacer()
                        if permissions.microphone == .notDetermined {
                            Button(permissions.requestingMicrophone ? "Requesting…" : "Enable microphone") { Task { await permissions.requestMicrophone() } }.disabled(permissions.requestingMicrophone)
                        }
                        Button("Open System Settings") { permissions.open(.microphone) }.accessibilityLabel("Open Microphone privacy settings")
                    }
                }.padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 12) {
                    permissionHeading("Screen & System Audio", symbol: "speaker.wave.2.fill", description: "Capture the other side of a meeting. SortMyMac saves audio only.", status: permissions.screenAllowed ? "Allowed" : "Not enabled", allowed: permissions.screenAllowed)
                    HStack {
                        Spacer()
                        if !permissions.screenAllowed && !permissions.screenRequestIssued {
                            Button("Request access") { permissions.requestScreen() }.accessibilityLabel("Request screen and system audio access")
                        }
                        Button("Open System Settings") { permissions.open(.screenRecording) }.accessibilityLabel("Open Screen and System Audio privacy settings")
                    }
                }.padding(.vertical, 4)
            }
            Section("Files & Folders") {
                Text("macOS controls access to protected folders such as Desktop, Documents, and Downloads. Access is requested when you use files from those folders.").font(.callout).foregroundStyle(.secondary)
                Button("Open Files & Folders Settings") { permissions.open(.filesAndFolders) }
            }
            Section {
                HStack { Text("Permission changes are controlled by macOS.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Refresh status") { permissions.refresh() } }
                if !permissions.message.isEmpty { Text(permissions.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }.formStyle(.grouped)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permissions.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in permissions.refresh() }
    }

    private func permissionHeading(_ title: String, symbol: String, description: String, status: String, allowed: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Color.accentColor).frame(width: 24, height: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 12)
            Label(status, systemImage: allowed ? "checkmark.circle.fill" : "circle.dashed").font(.caption).foregroundStyle(allowed ? Color.green : Color.secondary).fixedSize()
        }
    }
}
