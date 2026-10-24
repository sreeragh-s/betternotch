import AppKit
import SortMyMacCore
import SwiftUI
import UniformTypeIdentifiers

struct FolderDragHandle: NSViewRepresentable {
    let groups: [FileGroup]
    let model: AppModel
    let label: String
    func makeNSView(context: Context) -> FolderDragView {
        let view = FolderDragView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        return view
    }
    func updateNSView(_ view: FolderDragView, context: Context) {
        view.groups = groups; view.model = model
        view.toolTip = label + ". Or click to choose a destination."
        view.setAccessibilityLabel(label)
        view.setAccessibilityHelp("Drag into a Finder folder or onto the Desktop to move the original files. You can undo the move in Recovery.")
    }
}

@MainActor
final class FolderDragView: NSView, NSDraggingSource {
    var groups: [FileGroup] = []
    weak var model: AppModel?
    private var origin: CGPoint?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { origin = event.locationInWindow }
    override func mouseUp(with event: NSEvent) {
        if origin != nil { model?.chooseExportDestination(groups) }
        origin = nil
    }
    override var acceptsFirstResponder: Bool { true }
    override func accessibilityPerformPress() -> Bool {
        guard let model, model.phase == .grouped else { return false }
        model.chooseExportDestination(groups)
        return true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { _ = accessibilityPerformPress() }
        else { super.keyDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin, hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) > 4,
              let model, let providers = model.beginExport(groups) else { return }
        self.origin = nil
        model.activeDragSource = self
        let local = convert(event.locationInWindow, from: nil)
        let icon = NSWorkspace.shared.icon(for: .folder)
        let items = providers.enumerated().map { index, provider in
            let item = NSDraggingItem(pasteboardWriter: provider)
            item.setDraggingFrame(CGRect(x: local.x + CGFloat(index * 4), y: local.y, width: 44, height: 44), contents: icon)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.draggingFormation = .pile
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        model?.exportDragEnded(accepted: !operation.isEmpty)
        model?.activeDragSource = nil
    }
}

final class FolderPromise: NSObject, NSFilePromiseProviderDelegate, Sendable {
    let group: FileGroup
    let coordinator: any FolderExporting
    let started: @MainActor @Sendable (UUID) -> Bool
    let finished: @MainActor @Sendable (UUID, Result<MoveRecord, any Error>) -> Void
    private let queue: OperationQueue

    init(group: FileGroup, coordinator: any FolderExporting,
         started: @escaping @MainActor @Sendable (UUID) -> Bool,
         finished: @escaping @MainActor @Sendable (UUID, Result<MoveRecord, any Error>) -> Void) {
        self.group = group; self.coordinator = coordinator; self.started = started; self.finished = finished
        queue = OperationQueue()
        queue.name = "SortMyMac.folder-promise"
        queue.maxConcurrentOperationCount = 1
        super.init()
    }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        FolderNames.safeComponent(group.name)
    }
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        Task {
            guard await started(group.id) else {
                completionHandler(SortError.message("This drag session is no longer active. No originals were moved."))
                return
            }
            do {
                let record = try await coordinator.fulfill(group, at: url)
                completionHandler(nil)
                await finished(group.id, .success(record))
            } catch {
                completionHandler(error)
                await finished(group.id, .failure(error))
            }
        }
    }
}
