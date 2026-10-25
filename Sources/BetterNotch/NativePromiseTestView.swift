#if DEBUG
import AppKit
import BetterNotchCore
import SwiftUI

/// Disposable native drag acceptance fixture. The receiver is exercised only inside a real
/// performDragOperation callback, as AppKit requires; no user library or source files are used.
struct NativePromiseTestView: View {
    @ObservedObject var model: AppModel
    let destination: URL
    @State private var result = "Drag the staged folders from left to right."
    var body: some View {
        VStack(spacing: 20) {
            Text("Native file-promise test").font(.title2.bold())
            HStack(spacing: 20) {
                VStack(spacing: 12) {
                    Image(systemName: "folder.fill").font(.system(size: 40)).foregroundStyle(.blue)
                    Text("Drag staged folders")
                    Text("\(model.groups.count) folders").font(.caption).foregroundStyle(.secondary)
                }.frame(width: 150, height: 170)
                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .overlay { FolderDragHandle(groups: model.groups, model: model, label: "Drag staged test folders") }
                NativePromiseReceiver(destination: destination, result: $result)
                    .frame(maxWidth: .infinity, minHeight: 170)
                    .overlay { VStack(spacing: 12) { Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 40)); Text("Native receiver") }.allowsHitTesting(false) }
            }
            Text(result).font(.caption).foregroundStyle(.secondary)
            Text(model.status).font(.caption).multilineTextAlignment(.center)
            Button("Undo") { model.undoOrganization() }.disabled(!model.canUndoOrganization)
        }.padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black).foregroundStyle(.white).environment(\.colorScheme, .dark)
    }
}

private struct NativePromiseReceiver: NSViewRepresentable {
    let destination: URL
    @Binding var result: String
    func makeNSView(context: Context) -> NativePromiseReceiverView { NativePromiseReceiverView() }
    func updateNSView(_ view: NativePromiseReceiverView, context: Context) {
        view.destination = destination
        view.report = { result = $0 }
    }
}

private final class NativePromiseReceiverView: NSView {
    var destination: URL?
    var report: ((String) -> Void)?
    private var received = 0
    private let queue = OperationQueue()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        wantsLayer = true; layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.15).cgColor
        layer?.cornerRadius = 12
        setAccessibilityElement(true); setAccessibilityLabel("Native test destination")
    }
    required init?(coder: NSCoder) { nil }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        received = 0; layer?.borderColor = NSColor.systemGreen.cgColor; layer?.borderWidth = 2
        return .copy
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { layer?.borderWidth = 0 }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let destination, let receivers = sender.draggingPasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !receivers.isEmpty else { return false }
        report?("Receiving \(receivers.count) folders…")
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue) { [weak self] _, error in
                let message = error?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    received += 1
                    report?(message ?? "Received \(received) folders successfully")
                }
            }
        }
        return true
    }
}
#endif
