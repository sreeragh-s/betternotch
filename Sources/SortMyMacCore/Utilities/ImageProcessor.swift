import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

public enum ImageProcessor {
    public static var outputFormats: [String] {
        let supported = CGImageDestinationCopyTypeIdentifiers() as! [String]
        return ["jpeg", "png", "heic", "tiff"].filter { supported.contains(type($0).identifier) } + (WebPEncoder.available ? ["webp"] : [])
    }
    static func type(_ name: String) -> UTType {
        switch name { case "png": .png; case "heic": .heic; case "tiff": .tiff; default: .jpeg }
    }
    public static func render(_ file: FileDescriptor, kind: FileActionKind, settings s: ActionSettings, to output: URL) throws {
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, Int64(width) * Int64(height) <= 100_000_000,
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw SortError.message("Image cannot be decoded or exceeds 100 megapixels.") }
        let orientation = (properties[kCGImagePropertyOrientation as String] as? Int32) ?? 1
        var image = CIImage(cgImage: original).oriented(forExifOrientation: orientation)
        if kind == .removeBackground {
            let handler = VNImageRequestHandler(cgImage: original, orientation: CGImagePropertyOrientation(rawValue: UInt32(orientation)) ?? .up)
            let request = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([request]); try Task.checkCancellation()
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw SortError.message("No foreground subject was found.") }
            let mask = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
            image = image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: CIImage(cvPixelBuffer: mask)])
        }
        if kind == .cropImage {
            guard s.cropWidth > 0, s.cropHeight > 0, s.cropX >= 0, s.cropY >= 0,
                  s.cropX + s.cropWidth <= 1.00001, s.cropY + s.cropHeight <= 1.00001 else { throw SortError.message("Crop must fit inside the image.") }
            let e = image.extent
            let left = min(e.width - 1, (e.width * s.cropX).rounded())
            let bottom = min(e.height - 1, (e.height * s.cropY).rounded())
            let right = min(e.width, max(left + 1, (e.width * (s.cropX + s.cropWidth)).rounded()))
            let top = min(e.height, max(bottom + 1, (e.height * (s.cropY + s.cropHeight)).rounded()))
            image = image.cropped(to: CGRect(x: e.minX + left, y: e.minY + bottom, width: right - left, height: top - bottom))
        }
        if s.rotation != 0 {
            let orientations: [Int: CGImagePropertyOrientation] = [90: .right, 180: .down, 270: .left]
            guard let orientation = orientations[s.rotation] else { throw SortError.message("Choose a 0°, 90°, 180°, or 270° rotation.") }
            image = image.oriented(orientation)
        }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if kind == .resize || s.targetBytes > 0 {
            let e = image.extent
            let scale: Double
            switch s.resizeMode {
            case "percent": scale = s.percent / 100
            case "dimensions": scale = min(Double(max(1, s.width)) / e.width, s.height > 0 ? Double(s.height) / e.height : .greatestFiniteMagnitude)
            default: scale = Double(max(1, s.width)) / max(e.width, e.height)
            }
            guard scale > 0, scale <= 100, e.width * scale * e.height * scale <= 100_000_000 else { throw SortError.message("Choose output dimensions below 100 megapixels.") }
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        if s.format == "jpeg" {
            guard ["white", "black"].contains(s.jpegBackground) else { throw SortError.message("Choose a background color for JPEG.") }
            let color = s.jpegBackground == "white" ? CIColor.white : CIColor.black
            image = image.composited(over: CIImage(color: color).cropped(to: image.extent))
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cgImage = context.createCGImage(image, from: image.extent.integral) else { throw SortError.message("Could not render the image.") }
        var quality = min(1, max(0.05, s.quality))
        for attempt in 0..<8 {
            try Task.checkCancellation()
            if s.format == "webp" { try WebPEncoder.encode(cgImage, quality: Float(quality * 100), to: output) }
            else {
                guard outputFormats.contains(s.format), let destination = CGImageDestinationCreateWithURL(output as CFURL, type(s.format).identifier as CFString, 1, nil) else { throw SortError.message("This output format is unavailable on this Mac.") }
                CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: quality, kCGImagePropertyOrientation: 1] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw SortError.message("Could not encode the image.") }
            }
            let size = (try output.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            if s.targetBytes <= 0 || size <= s.targetBytes { return }
            if attempt == 7 || !["jpeg", "heic", "webp"].contains(s.format) { throw SortError.message("Cannot meet the target size at these dimensions. Reduce the dimensions or choose a lossy format.") }
            quality = max(0.05, quality * 0.7)
        }
    }
    public static func text(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    public static func text(at url: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4000] as CFDictionary) else { throw SortError.message("Cannot read this image.") }
        return try text(in: image)
    }
}

public struct ImagePreviewData: Sendable {
    public let data: Data
    public let width: Int
    public let height: Int
    public let bytes: Int64
}
extension ImageProcessor {
    public static func preview(_ url: URL) throws -> ImagePreviewData {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              Int64(width) * Int64(height) <= 100_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2400] as CFDictionary) else { throw SortError.message("Preview unavailable for this image.") }
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw SortError.message("Cannot encode preview.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SortError.message("Cannot encode preview.") }
        let rotated = [5, 6, 7, 8].contains(properties[kCGImagePropertyOrientation as String] as? Int ?? 1)
        return ImagePreviewData(data: data as Data, width: rotated ? height : width, height: rotated ? width : height, bytes: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
    }
}
