import AppKit
import SwiftUI
import Testing
@testable import BetterNotch

@MainActor private final class FileDragFixture: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard(name: .init("BetterNotch-DragTest-" + UUID().uuidString))
    var draggingSource: Any?
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}

@MainActor @Test func nativeFileDragRequiresAChosenTargetAndFinishesEachSessionOnce() {
    let info = FileDragFixture(); defer { info.draggingPasteboard.releaseGlobally() }
    let urls = [URL(fileURLWithPath: "/tmp/drop-fixture-a.txt"), URL(fileURLWithPath: "/tmp/drop-fixture-b.txt")]
    #expect(info.draggingPasteboard.writeObjects(urls as [NSURL]))
    let host = NotchHostingView(rootView: Text("Drop fixture"))
    var count = 0, choice: FileDropDestination? = .shelf, received: FileDropDestination?, ended: [Bool] = []
    host.dragEntered = { count = $0 }
    host.hoverDestination = { _ in choice }
    host.dragFinished = { ended.append($0) }
    host.receiveFiles = { files, target in #expect(files == urls); received = target; return true }
    #expect(host.draggingEntered(info) == .copy); #expect(count == 2)
    #expect(host.draggingUpdated(info) == .copy)
    choice = nil
    #expect(host.draggingUpdated(info).isEmpty)
    #expect(!host.prepareForDragOperation(info))
    #expect(!host.performDragOperation(info))
    host.draggingEnded(info)
    #expect(received == nil); #expect(ended == [false])
    choice = .organize
    #expect(host.draggingEntered(info) == .copy)
    #expect(host.prepareForDragOperation(info))
    #expect(host.performDragOperation(info))
    host.draggingEnded(info)
    #expect(received == .organize); #expect(ended == [false, true])
    #expect(host.draggingEntered(info) == .copy)
    host.draggingExited(info); host.draggingEnded(info)
    #expect(ended == [false, true, false])
}

@MainActor @Test func nativeDestinationIgnoresInternalAndNonFileDrags() {
    let info = FileDragFixture(); defer { info.draggingPasteboard.releaseGlobally() }
    let host = NotchHostingView(rootView: Text("Drop fixture"))
    var entered = false; host.dragEntered = { _ in entered = true }
    info.draggingPasteboard.setString("not a file", forType: .string)
    #expect(host.draggingEntered(info).isEmpty)
    info.draggingPasteboard.clearContents()
    info.draggingPasteboard.writeObjects([URL(fileURLWithPath: "/tmp/drop-fixture.txt") as NSURL])
    info.draggingSource = NSObject()
    #expect(host.draggingEntered(info).isEmpty)
    #expect(!entered)
}
