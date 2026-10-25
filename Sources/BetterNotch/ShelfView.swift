import AppKit
import QuickLookUI
import BetterNotchCore
import SwiftUI

struct ShelfView: View {
    @ObservedObject var hub: HubModel
    private var items: [ShelfItem] { hub.shelf.filter { (hub.route != .results || $0.managed) && (hub.route != .fileActions || hub.actionItems.contains($0.id)) }.sorted { $0.added > $1.added } }
    private var selectedItems: [ShelfItem] { items.filter { hub.selection.contains($0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: HubUI.section) {
            HStack {
                Text(hub.route == .results ? "Recent results" : hub.route == .fileActions ? "What would you like to do?" : "Your shelf").font(HubUI.title)
                Spacer(); Button("Add files…", action: hub.chooseFiles)
            }
            if !items.isEmpty {
                Text("Drag files to a folder or app to copy. Select several to drag them together.")
                    .font(HubUI.caption).foregroundStyle(.secondary)
            }
            if items.isEmpty {
                ContentUnavailableView("Your shelf is empty", systemImage: "tray", description: Text("Choose files or drag them toward the notch.")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) { ForEach(items) { item in fileTile(item) } }.padding(2)
                }.frame(height: 132)
                actions
                HStack {
                    Button(selectedItems.isEmpty ? "Select all" : "Deselect (\(selectedItems.count))") {
                        if selectedItems.isEmpty { hub.selection.formUnion(items.map(\.id)) }
                        else { hub.selection.subtract(selectedItems.map(\.id)) }
                    }.fixedSize()
                    if !selectedItems.isEmpty {
                        Button("Remove") { for item in selectedItems { hub.removeShelf(item) } }
                            .fixedSize().help("Remove selected shelf references. Files stay in place.")
                            .accessibilityLabel("Remove selected items from shelf")
                    }
                    Spacer()
                    Menu("Destinations") {
                        ForEach(hub.pins) { pin in
                            Menu(pin.name) {
                                Button("Copy to \(pin.name)") { hub.transfer(pin, moving: false) }
                                Button("Move into folder in \(pin.name)") { hub.transfer(pin, moving: true) }
                                Button("Unpin") { hub.pins.removeAll { $0.id == pin.id }; hub.removeStored("pins", pin.id) }
                            }
                        }
                        Button("Pin destination…", action: hub.pinDestination)
                    }.fixedSize()
                }.font(HubUI.caption)
            }
        }
    }
    private func fileTile(_ item: ShelfItem) -> some View {
        let url = item.resolvedURL()
        let toggleSelection = {
            if hub.selection.contains(item.id) { hub.selection.remove(item.id) } else { hub.selection.insert(item.id) }
        }
        return Button(action: toggleSelection) {
            VStack(spacing: 5) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: (url ?? item.file.url).path)).resizable().frame(width: 34, height: 34)
                Text(item.file.name).font(HubUI.caption.weight(.medium)).lineLimit(1)
                Text(url == nil ? "Missing · Locate" : item.file.typeIdentifier == "public.folder" ? "Folder" : ByteCountFormatter.string(fromByteCount: item.file.size, countStyle: .file)).font(HubUI.caption).foregroundStyle(url == nil ? .orange : .secondary)
            }.frame(width: 100, height: 100).padding(HubUI.gap)
                .background(hub.selection.contains(item.id) ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: HubUI.radius))
                .overlay(RoundedRectangle(cornerRadius: HubUI.radius).strokeBorder(hub.selection.contains(item.id) ? Color.accentColor : Color.primary.opacity(0.09), lineWidth: hub.selection.contains(item.id) ? 2 : 1))
                .overlay(alignment: .topTrailing) { if hub.selection.contains(item.id) { Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, Color.accentColor).font(.system(size: 15)).padding(6).accessibilityHidden(true) } }
        }.buttonStyle(.plain)
            .overlay {
                ShelfDragHandle(owner: hub.owner, urls: {
                    do { return try ShelfDragFiles.resolve(item, in: items, selection: hub.selection) }
                    catch { hub.error = error.localizedDescription; return [] }
                }, clicked: toggleSelection)
            }
            .help("Drag to copy into a folder or app. " + (url ?? item.file.url).path)
            .accessibilityLabel(item.file.name).accessibilityValue(hub.selection.contains(item.id) ? "Selected" : "Not selected")
            .contextMenu {
                if let url {
                    Button("Preview") { QuickLookController.shared.show(url) }
                    Button("Open") { NSWorkspace.shared.open(url) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("Save a copy…") { saveCopy(url) }
                    Button("Copy file") { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([url as NSURL]) }
                } else { Button("Locate…") { hub.locate(item) } }
                Button("Remove from shelf") { hub.removeShelf(item) }
                if item.managed { Button("Move result to Trash", role: .destructive) { hub.deleteManaged(item) } }
            }
    }
    private var actions: some View {
        let actions = FileActionDefinition.available(for: hub.selectedFiles)
        return HStack(spacing: 8) {
            ForEach(Array(actions.prefix(3))) { definition in
                Button { hub.open(definition) } label: { Label(definition.label, systemImage: definition.kind.symbol).lineLimit(1) }.buttonStyle(.bordered)
            }
            if actions.count > 3 { Menu("More") { ForEach(Array(actions.dropFirst(3))) { definition in Button(definition.label) { hub.open(definition) } } }.fixedSize() }
            if !hub.presets.isEmpty { Menu("Presets") { ForEach(hub.presets) { preset in Button(preset.name) { hub.applyPreset(preset) } } }.fixedSize() }
            Spacer(minLength: 0)
        }.frame(minHeight: 44)
    }
}

@MainActor
func saveCopy(_ url: URL) {
    let panel = NSSavePanel(); panel.nameFieldStringValue = url.lastPathComponent
    panel.begin { response in
        guard response == .OK, let destination = panel.url, destination.standardizedFileURL != url.standardizedFileURL else { return }
        do {
            // Stage next to the selected destination before atomically replacing an explicitly approved existing file.
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".betternotch-save-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: url, to: temporary)
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
            else { try FileManager.default.moveItem(at: temporary, to: destination) }
        } catch { NSAlert(error: error).runModal() }
    }
}

@MainActor
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = QuickLookController()
    private var url: URL?
    func show(_ url: URL) { self.url = url; guard let panel = QLPreviewPanel.shared() else { return }; panel.dataSource = self; panel.reloadData(); panel.makeKeyAndOrderFront(nil) }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { url as NSURL? }
}

struct FilePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView { let view = QLPreviewView(frame: .zero, style: .normal)!; view.autostarts = false; return view }
    func updateNSView(_ view: QLPreviewView, context: Context) { if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL } }
    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: ()) { nsView.close() }
}
