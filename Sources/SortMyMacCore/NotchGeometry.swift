import Foundation
import CoreGraphics

public struct NotchGeometry: Equatable, Sendable {
    public let screen: CGRect
    public let restingSize: CGSize
    public let expandedSize: CGSize
    public let hasCutout: Bool
    public let shadow: CGFloat = 28

    public init(screen: CGRect, safeTop: CGFloat, leftWidth: CGFloat? = nil, rightWidth: CGFloat? = nil, editor: Bool = false, availableHeight: CGFloat? = nil, activity: Bool = false) {
        self.screen = screen
        hasCutout = safeTop > 0
        let reported = screen.width - (leftWidth ?? 0) - (rightWidth ?? 0)
        let width = hasCutout && leftWidth != nil && rightWidth != nil && reported > 0
            ? reported : (hasCutout ? 190 : min(230, max(170, screen.width * 0.125)))
        restingSize = CGSize(width: activity ? min(screen.width - 64, width + 144) : width, height: max(30, safeTop))
        expandedSize = CGSize(width: min(editor ? 960 : 620, max(180, screen.width - 64)), height: min(editor ? 720 : 430, max(180, (availableHeight ?? screen.height) - 64)))
    }

    public var restingFrame: CGRect {
        CGRect(x: screen.midX - restingSize.width / 2, y: screen.maxY - restingSize.height,
               width: restingSize.width, height: restingSize.height)
    }

    public var expandedFrame: CGRect {
        CGRect(x: screen.midX - expandedSize.width / 2 - shadow,
               y: screen.maxY - expandedSize.height - shadow,
               width: expandedSize.width + shadow * 2, height: expandedSize.height + shadow)
    }

    public var activationFrame: CGRect { restingFrame.insetBy(dx: -22, dy: -16) }
}
