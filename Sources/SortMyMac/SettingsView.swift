import AppKit
import SwiftUI
import SortMyMacCore

@MainActor
final class SettingsWindow: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    init(model: AppModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 610),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "SortMyMac"
        window.minSize = NSSize(width: 760, height: 570)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { nil }
    func show() {
        if !(window?.contentView is NSHostingView<SettingsView>) { window?.contentView = NSHostingView(rootView: SettingsView(model: model, settings: model.settings)) }
        NSApp.activate(ignoringOtherApps: true)
        window?.center(); window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { window?.contentView = nil }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore
    @State private var checking = false
    @State private var connectionMessage = ""
    private let pages = [("Welcome", "sparkles"), ("Notch", "rectangle.topthird.inset.filled"), ("Cloudflare", "cloud"), ("Recovery", "arrow.uturn.backward")]

    var body: some View {
        NavigationSplitView {
            List(selection: $model.settingsPage) {
                ForEach(pages, id: \.0) { title, symbol in Label(title, systemImage: symbol).tag(title).padding(.vertical, 4) }
            }
            .listStyle(.sidebar).navigationSplitViewColumnWidth(190).frame(minWidth: 190)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch model.settingsPage {
                case "Notch": notchSettings
                case "Cloudflare": cloudSettings
                case "Recovery": RecoveryView(model: model)
                default: welcome
                }
            }.navigationTitle(model.settingsPage)
        }
        .frame(minWidth: 760, minHeight: 570)
    }

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 42)).foregroundStyle(Color.accentColor)
                    .frame(width: 76, height: 76).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 22))
                VStack(alignment: .leading, spacing: 8) {
                    Text("A little order.\nRight at the notch.").font(.system(size: 32, weight: .semibold))
                    Text("Bring related files together, then put them where they belong.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 18) {
                    step("1", "Bring your files", "Select files in Finder and drag them near the notch.")
                    step("2", "Find the connections", "Choose Organize. Clef groups files by topic or project.")
                    step("3", "Drop your folders", "Review the groups, then drag folders into Finder. Originals move at this step.")
                }
                Text("When you organize, filenames, metadata, limited document text, and small image previews are sent to Cloudflare using your account. Originals stay in place until you drop the folders into Finder.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Connect Cloudflare") { model.settingsPage = "Cloudflare" }.buttonStyle(.borderedProminent)
                    Button("Try the notch") {
                        settings.completedSetup = true
                        NSApp.keyWindow?.close()
                        model.showNotch()
                    }.buttonStyle(.bordered)
                }
            }.padding(32).frame(maxWidth: 650, alignment: .leading)
        }
    }

    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.system(size: 11, weight: .bold, design: .rounded))
                .frame(width: 24, height: 24).background(Color.accentColor.opacity(0.12), in: Circle()).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var notchSettings: some View {
        Form {
            Section("Appearance") {
                Picker("Display", selection: $settings.displayID) {
                    Text("Automatic (prefer built-in notch)").tag("automatic")
                    ForEach(NSScreen.screens, id: \.localizedName) { screen in
                        Text(screen.localizedName).tag(NotchController.identifier(screen))
                    }
                }
                HStack {
                    Text("Hover delay")
                    Slider(value: $settings.hoverDelay, in: 0.1...1, step: 0.1)
                    Text(settings.hoverDelay, format: .number.precision(.fractionLength(1))).monospacedDigit()
                    Text("s").foregroundStyle(.secondary)
                }
                Toggle("Haptic feedback on open", isOn: $settings.haptics)
            }
            Section {
                Text("Appearance and accent color follow your macOS settings automatically. The camera cutout stays black. The notch also follows macOS Reduce Motion. On displays without a camera cutout, SortMyMac appears as a small island at the top center.").font(.caption).foregroundStyle(.secondary)
                Button("Show notch") { model.showNotch() }
            }
        }.formStyle(.grouped)
    }

    private var cloudSettings: some View {
        Form {
            Section("Your Cloudflare account") {
                TextField("Account ID", text: $settings.accountID).textFieldStyle(.roundedBorder)
                SecureField("Workers AI API token", text: $settings.token).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save token in Keychain") { settings.saveToken() }
                    if !settings.credentialMessage.isEmpty { Text(settings.credentialMessage).font(.caption).foregroundStyle(.secondary) }
                }
                Text("Use a token with Workers AI Read access for this account. Your token stays on this Mac in Keychain.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button(checking ? "Testing connection…" : "Test connection") {
                    checking = true; connectionMessage = ""
                    let credentials = CloudflareCredentials(accountID: settings.accountID.trimmingCharacters(in: .whitespacesAndNewlines), token: settings.token.trimmingCharacters(in: .whitespacesAndNewlines))
                    Task {
                        do {
                            try await ClefClient(credentials: credentials).checkCredentials()
                            settings.saveToken()
                            settings.completedSetup = true
                            connectionMessage = "Connected to Cloudflare Clef. You’re ready to organize."
                        } catch { connectionMessage = error.localizedDescription }
                        checking = false
                    }
                }.disabled(checking)
                if !connectionMessage.isEmpty { Text(connectionMessage).font(.caption).textSelection(.enabled) }
            }
            Section("What leaves your Mac") {
                Text("Organize sends filenames, types, sizes, dates, limited extracted text, and small image previews to Cloudflare Clef. No files are uploaded before you choose Organize. No app backend or telemetry is used.")
                    .font(.callout).foregroundStyle(.secondary)
                Link("Cloudflare Workers AI documentation", destination: URL(string: "https://developers.cloudflare.com/workers-ai/models/clef/")!)
            }
        }.formStyle(.grouped)
    }
}
