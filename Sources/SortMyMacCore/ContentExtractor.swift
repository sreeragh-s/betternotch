import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public struct FileEvidence: Sendable {
    public let file: FileDescriptor
    public let excerpt: String
    public let preview: Data?
    public let isScreenshot: Bool
    public init(file: FileDescriptor, excerpt: String = "", preview: Data? = nil, isScreenshot: Bool = false) {
        self.file = file; self.excerpt = excerpt; self.preview = preview; self.isScreenshot = isScreenshot
    }
}

public actor ContentExtractor {
    public init() {}
    public func extract(_ file: FileDescriptor) throws -> FileEvidence {
        try Task.checkCancellation()
        try FileIntake.validateUnchanged(file)
        if ScreenshotDetector.isScreenshot(file) {
            try FileIntake.validateUnchanged(file)
            return FileEvidence(file: file, isScreenshot: true)
        }
        let type = UTType(file.typeIdentifier) ?? .data
        var excerpt = ""
        var preview: Data?
        // Large documents stay metadata-only. ImageIO creates a thumbnail without full-size decoding.
        if type.conforms(to: .image) {
            preview = thumbnail(file.url)
        } else if type.conforms(to: .pdf), file.size <= 25_000_000 {
            if let document = PDFDocument(url: file.url) {
                for index in 0..<min(document.pageCount, 4) {
                    try Task.checkCancellation()
                    excerpt += document.page(at: index)?.string ?? ""
                    if excerpt.count >= 1_200 { break }
                }
            }
        } else if file.url.pathExtension.lowercased() == "rtf", file.size <= 2_000_000 {
            let rich = try? NSAttributedString(url: file.url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            excerpt = rich?.string ?? ""
        } else if type.conforms(to: .text) || ["md", "json", "csv", "log", "yaml", "yml"].contains(file.url.pathExtension.lowercased()) {
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 16_384) ?? Data()
            excerpt = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? ""
        }
        try FileIntake.validateUnchanged(file)
        return FileEvidence(file: file, excerpt: String(excerpt.prefix(1_200)), preview: preview)
    }

    private func thumbnail(_ url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
