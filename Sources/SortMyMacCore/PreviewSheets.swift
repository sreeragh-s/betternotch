import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Packs small previews into at most four bounded sheets. Positions are described explicitly in the state.
/// This lets a 50-image session use the same 64-question batches as a text session.
enum PreviewSheets {
    static func make(_ previews: [Data]) throws -> [Data] {
        try stride(from: 0, to: previews.count, by: 16).map { start in
            let slice = Array(previews[start..<min(start + 16, previews.count)])
            let cell = 192
            let columns = min(4, slice.count)
            let rows = (slice.count + columns - 1) / columns
            guard let context = CGContext(data: nil, width: columns * cell, height: rows * cell,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw SortError.message("Could not prepare image previews.")
            }
            context.setFillColor(CGColor(gray: 0.08, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: columns * cell, height: rows * cell))
            for (index, data) in slice.enumerated() {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw SortError.message("Could not read an image preview. Remove that file and try again.")
                }
                let scale = min(CGFloat(cell - 12) / CGFloat(image.width), CGFloat(cell - 12) / CGFloat(image.height))
                let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
                let x = CGFloat((index % columns) * cell) + (CGFloat(cell) - width) / 2
                let y = CGFloat((rows - 1 - index / columns) * cell) + (CGFloat(cell) - height) / 2
                context.draw(image, in: CGRect(x: x, y: y, width: width, height: height))
            }
            let output = NSMutableData()
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw SortError.message("Could not encode image previews.")
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw SortError.message("Could not encode image previews.") }
            return output as Data
        }
    }
}
