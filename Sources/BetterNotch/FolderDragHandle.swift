import AppKit
import BetterNotchCore
import SwiftUI
import UniformTypeIdentifiers

/// Interactive SwiftUI controls keep their own mouse handling inside a card's drag surface.
struct FolderDragExclusions: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

struct FolderDragHandle: NSViewRepresentable {
    let groups: [FileGroup]
    let model: AppModel
    let label: String
    var passthroughRects: [CGRect] = []
    var cornerRadius: CGFloat = 0
    var tracksCardMouseEvents = false
    func makeNSView(context: Context) -> FolderDragView {
        let view = FolderDragView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        return view
    }
    func updateNSView(_ view: FolderDragView, context: Context) {
        view.groups = groups; view.model = model
        view.passthroughRects = passthroughRects
        view.cornerRadius = cornerRadius
        view.tracksCardMouseEvents = tracksCardMouseEvents
        view.toolTip = label + ". Or click to choose a destination."
        view.setAccessibilityLabel(label)
        view.setAccessibilityHelp("Drag into a Finder folder or onto the Desktop to move the original files. You can undo the move in Recovery.")
    }
    static func dismantleNSView(_ view: FolderDragView, coordinator: ()) {
        view.stopMonitoringMouseEvents()
    }
}

@MainActor
final class FolderDragView: NSView, NSDraggingSource {
    var groups: [FileGroup] = []
    weak var model: AppModel?
    var passthroughRects: [CGRect] = []
    var cornerRadius: CGFloat = 0
    var tracksCardMouseEvents = false {
        didSet { if tracksCardMouseEvents != oldValue { updateEventMonitor() } }
    }
    private var origin: CGPoint?
    private var mouseMonitor: Any?
    override var isFlipped: Bool { true }
    func containsDragPoint(_ point: CGPoint) -> Bool {
        !isHiddenOrHasHiddenAncestor && visibleRect.contains(point)
            && NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).contains(point)
            && !passthroughRects.contains(where: { $0.contains(point) })
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !tracksCardMouseEvents, containsDragPoint(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateEventMonitor()
    }
    func stopMonitoringMouseEvents() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        origin = nil
    }
    private func updateEventMonitor() {
        stopMonitoringMouseEvents()
        guard tracksCardMouseEvents, window != nil else { return }
        // Observe only left-button gestures. SwiftUI retains normal hit testing for
        // file context menus, scrolling, name editing, and the overflow menu.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            return self.trackCardMouseEvent(event)
        }
    }
    private func trackCardMouseEvent(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else {
            if event.type == .leftMouseDown { origin = nil }
            return event
        }
        switch event.type {
        case .leftMouseDown:
            origin = nil
            guard !event.modifierFlags.contains(.control), model?.phase == .grouped,
                  containsDragPoint(convert(event.locationInWindow, from: nil)) else { return event }
            mouseDown(with: event)
        case .leftMouseDragged:
            guard origin != nil else { return event }
            mouseDragged(with: event)
            if origin == nil { return nil }
        case .leftMouseUp:
            guard origin != nil else { return event }
            if containsDragPoint(convert(event.locationInWindow, from: nil)) { mouseUp(with: event) }
            else { origin = nil }
        default: break
        }
        return event
    }
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
        queue.name = "BetterNotch.folder-promise"
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
