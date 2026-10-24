import CoreGraphics
import Foundation

/// Normalized, top-left coordinates used by the editor. The processor's bottom-left
/// crop settings are converted only at the view boundary, before rotation.
public struct CropSelection: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public static let full = CropSelection(x: 0, y: 0, width: 1, height: 1)
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var center: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }
    public var isFull: Bool { abs(x) < 0.0001 && abs(y) < 0.0001 && width > 0.9999 && height > 0.9999 }
    public func clamped(minimum: Double = 0.002) -> Self {
        guard [x, y, width, height].allSatisfy(\.isFinite) else { return .full }
        let w = min(1, max(minimum, width)), h = min(1, max(minimum, height))
        return Self(x: min(max(0, x), 1 - w), y: min(max(0, y), 1 - h), width: w, height: h)
    }
    public func frame(in bounds: CGRect) -> CGRect { CGRect(x: bounds.minX + x * bounds.width, y: bounds.minY + y * bounds.height, width: width * bounds.width, height: height * bounds.height) }
    public func rotated(clockwise degrees: Int) -> Self {
        switch ((degrees % 360) + 360) % 360 {
        case 90: Self(x: 1 - maxY, y: x, width: height, height: width)
        case 180: Self(x: 1 - maxX, y: 1 - maxY, width: width, height: height)
        case 270: Self(x: y, y: 1 - maxX, width: height, height: width)
        default: self
        }
    }
    public func pixelRect(in size: CGSize) -> CGRect {
        let c = clamped()
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        let left = min(w - 1, max(0, Int((c.x * Double(w)).rounded())))
        let top = min(h - 1, max(0, Int((c.y * Double(h)).rounded())))
        let right = min(w, max(left + 1, Int((c.maxX * Double(w)).rounded())))
        let bottom = min(h, max(top + 1, Int((c.maxY * Double(h)).rounded())))
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
    public func aligned(to size: CGSize) -> Self {
        guard size.width > 0, size.height > 0 else { return self }
        let rect = pixelRect(in: size)
        return Self(x: rect.minX / size.width, y: rect.minY / size.height, width: rect.width / size.width, height: rect.height / size.height)
    }
    public func fitted(aspect ratio: Double?) -> Self {
        guard let ratio, ratio.isFinite, ratio > 0 else { return clamped() }
        var w = width, h = height
        if w / h > ratio { w = h * ratio } else { h = w / ratio }
        return Self(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h).clamped(minimum: 0.000001)
    }
}

public enum CropHandle: String, CaseIterable, Sendable {
    case new, move, topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    public var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }
    public func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        default: CGPoint(x: rect.midX, y: rect.midY)
        }
    }
}

public enum CropGeometry {
    public static func imageFrame(size: CGSize, in canvas: CGSize, inset: Double = 28) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let available = CGSize(width: max(1, canvas.width - inset * 2), height: max(1, canvas.height - inset * 2))
        let scale = min(available.width / size.width, available.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: (canvas.width - width) / 2, y: (canvas.height - height) / 2, width: width, height: height)
    }
    public static func normalized(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: (point.x - frame.minX) / max(1, frame.width), y: (point.y - frame.minY) / max(1, frame.height))
    }
    /// Every event uses the rectangle captured at gesture start, avoiding accumulated deltas.
    public static func drag(_ handle: CropHandle, initial: CropSelection, start: CGPoint, current: CGPoint, aspect: Double? = nil) -> CropSelection {
        let c = initial.clamped(), minimum = 0.002
        let dx = current.x - start.x, dy = current.y - start.y
        let ratio = aspect.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if handle == .move {
            return CropSelection(x: min(max(0, c.x + dx), 1 - c.width), y: min(max(0, c.y + dy), 1 - c.height), width: c.width, height: c.height)
        }
        if handle == .new || handle.isCorner {
            let anchor: CGPoint
            let sx: Double, sy: Double
            let desired: CGPoint
            switch handle {
            case .topLeft: anchor = CGPoint(x: c.maxX, y: c.maxY); sx = -1; sy = -1; desired = CGPoint(x: c.x + dx, y: c.y + dy)
            case .topRight: anchor = CGPoint(x: c.x, y: c.maxY); sx = 1; sy = -1; desired = CGPoint(x: c.maxX + dx, y: c.y + dy)
            case .bottomLeft: anchor = CGPoint(x: c.maxX, y: c.y); sx = -1; sy = 1; desired = CGPoint(x: c.x + dx, y: c.maxY + dy)
            case .bottomRight: anchor = CGPoint(x: c.x, y: c.y); sx = 1; sy = 1; desired = CGPoint(x: c.maxX + dx, y: c.maxY + dy)
            default:
                anchor = CGPoint(x: min(1, max(0, start.x)), y: min(1, max(0, start.y)))
                sx = current.x >= start.x ? 1 : -1; sy = current.y >= start.y ? 1 : -1; desired = current
            }
            let maxW = sx > 0 ? 1 - anchor.x : anchor.x, maxH = sy > 0 ? 1 - anchor.y : anchor.y
            var w = min(maxW, max(minimum, (desired.x - anchor.x) * sx))
            var h = min(maxH, max(minimum, (desired.y - anchor.y) * sy))
            if let ratio {
                w = min(max(w, h * ratio), maxW, maxH * ratio); h = w / ratio
            }
            guard w > 0.000001, h > 0.000001 else { return c }
            return CropSelection(x: sx > 0 ? anchor.x : anchor.x - w, y: sy > 0 ? anchor.y : anchor.y - h, width: w, height: h)
        }
        var x = c.x, y = c.y, w = c.width, h = c.height
        switch handle {
        case .left: x = min(max(0, c.x + dx), c.maxX - minimum); w = c.maxX - x
        case .right: w = min(1 - c.x, max(minimum, c.width + dx))
        case .top: y = min(max(0, c.y + dy), c.maxY - minimum); h = c.maxY - y
        case .bottom: h = min(1 - c.y, max(minimum, c.height + dy))
        default: break
        }
        if let ratio {
            if handle == .left || handle == .right {
                w = min(w, 2 * min(c.center.y, 1 - c.center.y) * ratio); h = w / ratio
                y = c.center.y - h / 2; x = handle == .left ? c.maxX - w : c.x
            } else {
                h = min(h, 2 * min(c.center.x, 1 - c.center.x) / ratio); w = h * ratio
                x = c.center.x - w / 2; y = handle == .top ? c.maxY - h : c.y
            }
        }
        return CropSelection(x: x, y: y, width: w, height: h).clamped(minimum: 0.000001)
    }
}
