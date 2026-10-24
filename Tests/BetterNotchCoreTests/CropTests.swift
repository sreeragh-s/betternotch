import CoreGraphics
import Testing
@testable import BetterNotchCore

@Test func cropDrawsInEitherDirectionAndStaysInsideImage() {
    let forward = CropGeometry.drag(.new, initial: .full, start: CGPoint(x: 0.2, y: 0.1), current: CGPoint(x: 0.8, y: 0.6))
    let reverse = CropGeometry.drag(.new, initial: .full, start: CGPoint(x: 0.8, y: 0.6), current: CGPoint(x: 0.2, y: 0.1))
    #expect(abs(forward.x - reverse.x) < 0.000001)
    #expect(abs(forward.height - 0.5) < 0.000001)
    let outside = CropGeometry.drag(.new, initial: .full, start: CGPoint(x: 0.2, y: 0.1), current: CGPoint(x: 3, y: 4))
    #expect(outside.maxX <= 1); #expect(outside.maxY <= 1)
}
@Test func cropMoveUsesOriginalGestureSnapshotAndClampsWithoutResizing() {
    let initial = CropSelection(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
    let moved = CropGeometry.drag(.move, initial: initial, start: .zero, current: CGPoint(x: 1, y: -1))
    #expect(moved.width == initial.width); #expect(moved.height == initial.height)
    #expect(moved.x == 0.6); #expect(moved.y == 0)
}
@Test func cropAspectLocksWorkForCornerAndEdgeHandlesAtBounds() {
    let initial = CropSelection(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
    for handle in CropHandle.allCases where handle != .move {
        let result = CropGeometry.drag(handle, initial: initial, start: CGPoint(x: 0.4, y: 0.4), current: CGPoint(x: 1.2, y: 0.9), aspect: 1)
        #expect(abs(result.width / result.height - 1) < 0.000001)
        #expect(result.x >= -0.000001); #expect(result.y >= -0.000001)
        #expect(result.maxX <= 1.000001); #expect(result.maxY <= 1.000001)
    }
}
@Test func cropRotationRoundTripsAndExportCoordinatesMatchDisplayedSelection() {
    let selection = CropSelection(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
    for rotation in [0, 90, 180, 270] {
        let display = selection.rotated(clockwise: rotation)
        let restored = display.rotated(clockwise: -rotation)
        #expect(abs(restored.x - selection.x) < 0.000001)
        #expect(abs(restored.y - selection.y) < 0.000001)
        #expect(abs(restored.width - selection.width) < 0.000001)
        #expect(abs(restored.height - selection.height) < 0.000001)
    }
    let pixels = selection.pixelRect(in: CGSize(width: 800, height: 500))
    #expect(pixels == CGRect(x: 80, y: 100, width: 400, height: 200))
    #expect(abs((1 - selection.maxY) * 500 - 200) < 0.000001)
}
@Test func cropHandlesCannotCrossTheirOppositeAnchor() {
    let selection = CropSelection(x: 0.2, y: 0.2, width: 0.6, height: 0.5)
    let result = CropGeometry.drag(.topLeft, initial: selection, start: CGPoint(x: 0.2, y: 0.2), current: CGPoint(x: 2, y: 2))
    #expect(result.width > 0); #expect(result.height > 0)
    #expect(abs(result.maxX - selection.maxX) < 0.000001)
    #expect(abs(result.maxY - selection.maxY) < 0.000001)
}
@Test func cropCanvasIgnoresLetterboxMarginsWhenMappingPointer() {
    let frame = CropGeometry.imageFrame(size: CGSize(width: 800, height: 400), in: CGSize(width: 600, height: 500))
    #expect(frame.width == 544); #expect(frame.height == 272)
    let point = CropGeometry.normalized(CGPoint(x: frame.midX, y: frame.midY), in: frame)
    #expect(point == CGPoint(x: 0.5, y: 0.5))
}
