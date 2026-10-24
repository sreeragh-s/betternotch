import AppKit

let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
let sizes = [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
             (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"),
             (512, "512x512"), (1024, "512x512@2x")]
for (pixels, name) in sizes {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let background = NSBezierPath(roundedRect: NSRect(x: size * 0.06, y: size * 0.06, width: size * 0.88, height: size * 0.88),
                                  xRadius: size * 0.22, yRadius: size * 0.22)
    NSColor(calibratedRed: 0.035, green: 0.065, blue: 0.065, alpha: 1).setFill()
    background.fill()
    let gradient = NSGradient(starting: NSColor(calibratedRed: 0.14, green: 0.91, blue: 0.75, alpha: 1),
                              ending: NSColor(calibratedRed: 0.25, green: 0.75, blue: 0.87, alpha: 1))!
    for layer in 0..<3 {
        let path = NSBezierPath()
        if layer == 2 {
            path.move(to: NSPoint(x: size * 0.24, y: size * 0.64))
            path.line(to: NSPoint(x: size * 0.50, y: size * 0.505))
            path.line(to: NSPoint(x: size * 0.76, y: size * 0.64))
            path.line(to: NSPoint(x: size * 0.50, y: size * 0.775))
        } else {
            let y = size * (0.34 + Double(layer) * 0.16)
            path.move(to: NSPoint(x: size * 0.24, y: y))
            path.line(to: NSPoint(x: size * 0.50, y: y - size * 0.135))
            path.line(to: NSPoint(x: size * 0.76, y: y))
            path.line(to: NSPoint(x: size * 0.76, y: y + size * 0.07))
            path.line(to: NSPoint(x: size * 0.50, y: y - size * 0.065))
            path.line(to: NSPoint(x: size * 0.24, y: y + size * 0.07))
        }
        path.close()
        gradient.draw(in: path, angle: 25)
    }
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("icon_\(name).png"))
}
