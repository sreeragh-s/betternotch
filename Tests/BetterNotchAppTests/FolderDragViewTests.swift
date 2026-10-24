import AppKit
import Testing
@testable import BetterNotch

@MainActor
@Test func folderCardDragSurfaceCoversContentAndPadding() {
    let parent = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
    let card = FolderDragView(frame: CGRect(x: 30, y: 20, width: 270, height: 100))
    card.tracksCardMouseEvents = true
    parent.addSubview(card)
    // Local coordinates match the SwiftUI card, including its top-left origin.
    for point in [CGPoint(x: 24, y: 28), CGPoint(x: 90, y: 48),
                  CGPoint(x: 24, y: 75), CGPoint(x: 250, y: 80), CGPoint(x: 135, y: 5)] {
        #expect(card.containsDragPoint(point))
        #expect(parent.hitTest(card.convert(point, to: parent)) !== card)
    }
}

@MainActor
@Test func folderCardDragSurfaceLeavesNameAndMenuInteractive() {
    let parent = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
    let content = NSView(frame: parent.bounds)
    parent.addSubview(content)
    let card = FolderDragView(frame: CGRect(x: 30, y: 20, width: 270, height: 100))
    card.passthroughRects = [CGRect(x: 52, y: 12, width: 200, height: 18),
                            CGRect(x: 150, y: 64, width: 35, height: 22)]
    card.tracksCardMouseEvents = true
    parent.addSubview(card)
    for point in [CGPoint(x: 90, y: 20), CGPoint(x: 165, y: 75)] {
        #expect(!card.containsDragPoint(point))
        #expect(parent.hitTest(card.convert(point, to: parent)) === content)
    }
    #expect(card.containsDragPoint(CGPoint(x: 90, y: 45)))
}

@MainActor
@Test func folderCardDragSurfaceDoesNotCatchOutsideClicks() {
    let parent = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
    let card = FolderDragView(frame: CGRect(x: 30, y: 20, width: 270, height: 100))
    card.cornerRadius = 13
    parent.addSubview(card)
    for point in [CGPoint(x: 1, y: 1), CGPoint(x: -1, y: 50), CGPoint(x: 271, y: 50)] {
        #expect(parent.hitTest(card.convert(point, to: parent)) !== card)
    }
    #expect(parent.hitTest(card.convert(CGPoint(x: 14, y: 5), to: parent)) === card)
}
