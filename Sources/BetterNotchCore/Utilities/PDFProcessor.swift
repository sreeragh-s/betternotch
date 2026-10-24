import AppKit
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public enum PDFProcessor {
    public static func pageIndices(_ expression: String, count: Int) throws -> [Int] {
        if expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Array(0..<count) }
        var indices: [Int] = []
        for token in expression.split(separator: ",", omittingEmptySubsequences: false) {
            let components = token.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(components.count), let first = Int(components[0]), first > 0, first <= count else { throw SortError.message("Enter valid page numbers, such as 1,3-5,2.") }
            let last: Int
            if components.count == 2 { guard let value = Int(components[1]), value >= first, value <= count else { throw SortError.message("Page range is outside this document.") }; last = value } else { last = first }
            indices += (first...last).map { $0 - 1 }
        }
        guard !indices.isEmpty else { throw SortError.message("Choose at least one page.") }
        return indices
    }
    static func document(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url), !document.isLocked else { throw SortError.message("PDF is damaged or password protected. Unlock it first.") }
        return document
    }
    public static func render(_ inputs: [FileDescriptor], kind: FileActionKind, settings: ActionSettings, to output: URL) throws {
        let result = PDFDocument()
        if kind == .makePDF {
            for file in inputs {
                try Task.checkCancellation()
                if UTType(file.typeIdentifier)?.conforms(to: .image) == true {
                    guard let image = NSImage(contentsOf: file.url), let page = PDFPage(image: image) else { throw SortError.message("Cannot create an image page.") }
                    result.insert(page, at: result.pageCount)
                } else {
                    let text = try extractedText(file)
                    let data = try textPDF(text)
                    guard let document = PDFDocument(data: data) else { throw SortError.message("Cannot create text pages.") }
                    for i in 0..<document.pageCount { if let page = document.page(at: i)?.copy() as? PDFPage { result.insert(page, at: result.pageCount) } }
                }
            }
        } else {
            for file in inputs {
                let doc = try document(file.url)
                let indices = try pageIndices(kind == .mergePDF ? "" : settings.pages, count: doc.pageCount)
                for i in indices {
                    try Task.checkCancellation()
                    guard let page = doc.page(at: i)?.copy() as? PDFPage else { throw SortError.message("Cannot read PDF page \(i + 1).") }
                    if kind == .compressPDF {
                        let bounds = page.bounds(for: .mediaBox)
                        let size = CGSize(width: min(1600, bounds.width * 1.5), height: min(2400, bounds.height * 1.5))
                        let image = page.thumbnail(of: size, for: .mediaBox)
                        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: settings.quality]),
                              let compressed = NSImage(data: jpeg), let rasterPage = PDFPage(image: compressed) else { throw SortError.message("Cannot compress this page.") }
                        rasterPage.setBounds(bounds, for: .mediaBox)
                        result.insert(rasterPage, at: result.pageCount)
                    } else {
                        page.rotation = (page.rotation + settings.rotation) % 360
                        result.insert(page, at: result.pageCount)
                    }
                }
            }
        }
        guard result.pageCount > 0, result.write(to: output), let checked = PDFDocument(url: output), checked.pageCount == result.pageCount else { throw SortError.message("PDF output validation failed.") }
    }
    public static func extractedText(_ file: FileDescriptor) throws -> String {
        let type = UTType(file.typeIdentifier) ?? .data
        if type.conforms(to: .image) { return try ImageProcessor.text(at: file.url) }
        if type.conforms(to: .pdf) {
            let doc = try document(file.url)
            var pages: [String] = []
            for index in 0..<doc.pageCount {
                try Task.checkCancellation()
                guard let page = doc.page(at: index) else { continue }
                var text = page.string ?? ""
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let image = page.thumbnail(of: CGSize(width: 2000, height: 2600), for: .mediaBox)
                    if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { text = try ImageProcessor.text(in: cg) }
                }
                pages.append("Page \(index + 1)\n\(text)")
            }
            return pages.joined(separator: "\n\n")
        }
        guard file.size <= 20_000_000 else { throw SortError.message("Text documents are limited to 20 MB.") }
        if file.url.pathExtension.lowercased() == "rtf" { return try NSAttributedString(url: file.url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string }
        return try String(contentsOf: file.url, encoding: .utf8)
    }
    private static func textPDF(_ text: String) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw SortError.message("Cannot create PDF context.") }
        let style = [kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 12, nil)]
        let attributed = NSAttributedString(string: text.isEmpty ? " " : text, attributes: style)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var offset = 0
        while offset < attributed.length {
            try Task.checkCancellation()
            context.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: [Double(0), 0, 612, 792], length: 32)] as CFDictionary)
            let path = CGPath(rect: CGRect(x: 42, y: 42, width: 528, height: 708), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
            CTFrameDraw(frame, context); context.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { throw SortError.message("Text cannot fit on a PDF page.") }
            offset += visible.length
        }
        context.closePDF(); return data as Data
    }
}
