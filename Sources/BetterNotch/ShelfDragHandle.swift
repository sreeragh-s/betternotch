import AppKit
import BetterNotchCore
import SwiftUI

enum ShelfDragFiles {
    /// Resolve bookmarks when the gesture starts. Never silently omit a selected missing file.
    static func resolve(_ item: ShelfItem, in visibleItems: [ShelfItem], selection: Set<UUID>) throws -> [URL] {
        let batch = selection.contains(item.id) ? visibleItems.filter { selection.contains($0.id) } : [item]
        var seen = Set<URL>()
        return try batch.compactMap { item in
            guard let url = item.resolvedURL() else {
                throw SortError.message("Locate \(item.file.name) before dragging. Right-click it and choose Locate…")
            }
            return seen.insert(url.standardizedFileURL).inserted ? url : nil
        }
    }
}

struct ShelfDragHandle: NSViewRepresentable {
    let owner: AppModel?
    let urls: () -> [URL]
    let clicked: () -> Void

    func makeNSView(context: Context) -> ShelfDragView {
        let view = ShelfDragView()
        // The SwiftUI button owns keyboard actions, context menus and accessibility.
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: ShelfDragView, context: Context) {
        view.owner = owner; view.urls = urls; view.clicked = clicked
    }
}

@MainActor
final class ShelfDragView: NSView, NSDraggingSource {
    weak var owner: AppModel?
    var urls: () -> [URL] = { [] }
    var clicked: () -> Void = {}
    private var origin: CGPoint?
    override var isFlipped: Bool { true }

    func containsDragPoint(_ point: CGPoint) -> Bool {
        !isHiddenOrHasHiddenAncestor && visibleRect.contains(point)
            && NSBezierPath(roundedRect: bounds, xRadius: HubUI.radius, yRadius: HubUI.radius).contains(point)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Leave secondary clicks and horizontal scrolling to SwiftUI/the scroll view.
        if let event = NSApp.currentEvent,
           ![.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type) || event.modifierFlags.contains(.control) { return nil }
        guard containsDragPoint(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { origin = event.locationInWindow }
    override func mouseUp(with event: NSEvent) {
        defer { origin = nil }
        if origin != nil, containsDragPoint(convert(event.locationInWindow, from: nil)) { clicked() }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin, hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) > 4 else { return }
        self.origin = nil
        let files = urls()
        guard !files.isEmpty else { return }
        let local = convert(event.locationInWindow, from: nil)
        let items = Self.draggingItems(for: files, at: local)
        owner?.activeDragSource = self
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.draggingFormation = .pile
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    static func draggingItems(for urls: [URL], at point: CGPoint) -> [NSDraggingItem] {
        urls.enumerated().map { index, url in
            // File URLs let Finder copy the original name and let apps receive real attachments.
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(CGRect(x: point.x + CGFloat(index * 4), y: point.y, width: 40, height: 40),
                                  contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if owner?.activeDragSource === self { owner?.activeDragSource = nil }
    }
}
