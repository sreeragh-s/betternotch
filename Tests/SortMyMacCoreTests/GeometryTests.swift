import Foundation
import Testing
@testable import SortMyMacCore

@Test func usesReportedCutoutAndPreservesScreenOrigin() {
    let g = NotchGeometry(screen: CGRect(x: -1728, y: 120, width: 1728, height: 1117), safeTop: 38, leftWidth: 760, rightWidth: 760)
    #expect(g.hasCutout)
    #expect(g.restingSize.width == 208)
    #expect(g.restingFrame.maxY == 1237)
    #expect(g.expandedFrame.midX == -864)
}

@Test func islandFitsSmallAndLargeDisplays() {
    for width in [320.0, 640, 1920, 5120] {
        let g = NotchGeometry(screen: CGRect(x: 0, y: 0, width: width, height: 1080), safeTop: 0)
        #expect(!g.hasCutout)
        #expect(g.restingSize.width >= 170 && g.restingSize.width <= 230)
        #expect(g.expandedFrame.minX >= 0)
        #expect(g.expandedFrame.maxX <= width)
    }
}
