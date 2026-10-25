import AppKit
import BetterNotchCore
import Testing
@testable import BetterNotch

private func withShelfFiles(_ body: (URL, [ShelfItem]) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("BetterNotch-ShelfDrag-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let items = try ["Notes with spaces.txt", "画像.txt", "Result.txt"].map { name in
        let url = root.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return ShelfItem(file: try FileIntake.describe(url), managed: name == "Result.txt")
    }
    try body(root, items)
}

@MainActor @Test func draggingSelectedShelfTileIncludesOnlyVisibleSelection() throws {
    try withShelfFiles { (_, items) throws in
        let selection = Set(items.map(\.id))
        let all = try ShelfDragFiles.resolve(items[0], in: items, selection: selection)
        #expect(all.map { $0.resolvingSymlinksInPath().path } == items.map { $0.file.url.resolvingSymlinksInPath().path })
        // Recent Results/file-action views must not drag selected files hidden on another route.
        let results = try ShelfDragFiles.resolve(items[2], in: [items[2]], selection: selection)
        let unselected = try ShelfDragFiles.resolve(items[0], in: items, selection: [items[1].id])
        let single = try ShelfDragFiles.resolve(items[0], in: items, selection: [])
        #expect(results.map { $0.resolvingSymlinksInPath().path } == [items[2].file.url.resolvingSymlinksInPath().path])
        #expect(unselected.map { $0.resolvingSymlinksInPath().path } == [items[0].file.url.resolvingSymlinksInPath().path])
        #expect(single.map { $0.resolvingSymlinksInPath().path } == [items[0].file.url.resolvingSymlinksInPath().path])
    }
}

@MainActor @Test func shelfDragRejectsMissingOrReplacedSelectedFiles() throws {
    try withShelfFiles { (root, items) throws in
        let url = items[1].file.url
        // Retain the old inode so a replacement cannot accidentally reuse its identity.
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("removed.txt"))
        var missing = items[1]; missing.bookmark = nil
        let visible = [items[0], missing]
        let selection: Set<UUID> = [items[0].id, missing.id]
        #expect(throws: (any Error).self) { try ShelfDragFiles.resolve(items[0], in: visible, selection: selection) }
        try Data("replacement".utf8).write(to: url)
        #expect(throws: (any Error).self) { try ShelfDragFiles.resolve(items[0], in: visible, selection: selection) }
        let single = try ShelfDragFiles.resolve(items[0], in: visible, selection: [])
        #expect(single.map { $0.resolvingSymlinksInPath().path } == [items[0].file.url.resolvingSymlinksInPath().path])
    }
}

@MainActor @Test func shelfDragPublishesOneFileURLPerFileAndPreservesOriginals() throws {
    try withShelfFiles { (root, items) throws in
        let folder = root.appendingPathComponent("Folder with files", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let child = folder.appendingPathComponent("child.txt")
        try Data("folder contents".utf8).write(to: child)
        let urls = items.map(\.file.url) + [folder]
        let draggingItems = ShelfDragView.draggingItems(for: urls, at: CGPoint(x: 20, y: 30))
        let pasteboard = NSPasteboard(name: .init("BetterNotch-ShelfDrag-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        #expect(draggingItems.count == urls.count)
        let writers = draggingItems.compactMap { $0.item as? any NSPasteboardWriting }
        #expect(writers.count == urls.count)
        #expect(pasteboard.writeObjects(writers))
        #expect(pasteboard.pasteboardItems?.allSatisfy { $0.types.contains(.fileURL) } == true)
        let received = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(received == urls)
        // Simulate a receiver copying URLs read from the native pasteboard.
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for url in try #require(received) {
            let target = destination.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: target)
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(FileManager.default.fileExists(atPath: target.path))
        }
        #expect(try String(contentsOf: child, encoding: .utf8) == "folder contents")
        #expect(try String(contentsOf: destination.appendingPathComponent("Folder with files/child.txt"), encoding: .utf8) == "folder contents")
    }
}

@MainActor @Test func shelfTileClickSelectsWithoutDraggingAndOutsideReleaseDoesNothing() throws {
    let parent = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
    let view = ShelfDragView(frame: CGRect(x: 30, y: 20, width: 116, height: 116))
    parent.addSubview(view)
    var clicks = 0, payloadRequests = 0
    view.clicked = { clicks += 1 }; view.urls = { payloadRequests += 1; return [] }
    func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    }
    let inside = view.convert(CGPoint(x: 50, y: 50), to: nil)
    view.mouseDown(with: try event(.leftMouseDown, at: inside))
    view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: inside.x + 2, y: inside.y)))
    view.mouseUp(with: try event(.leftMouseUp, at: inside))
    #expect(clicks == 1); #expect(payloadRequests == 0)
    view.mouseDown(with: try event(.leftMouseDown, at: inside))
    view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: inside.x + 10, y: inside.y)))
    view.mouseUp(with: try event(.leftMouseUp, at: inside))
    #expect(clicks == 1); #expect(payloadRequests == 1)
    view.mouseDown(with: try event(.leftMouseDown, at: inside))
    view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 300, y: 150)))
    #expect(clicks == 1)
    for point in [CGPoint(x: 10, y: 10), CGPoint(x: 55, y: 55), CGPoint(x: 105, y: 105)] {
        #expect(view.containsDragPoint(point))
    }
    #expect(!view.containsDragPoint(CGPoint(x: -1, y: 55)))
}
