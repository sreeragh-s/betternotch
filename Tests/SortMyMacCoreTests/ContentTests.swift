import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SortMyMacCore

func tinyPNG() throws -> Data {
    let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.8, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Test func fiftyPreviewsFitFourSheetsWithExplicitCellLocations() async throws {
    let png = try tinyPNG()
    let inputs = (0..<50).map { evidence("image\($0).png", preview: png) }
    let pairs = try #require(ClefGroupingService.batches(inputs).first)
    let answers = Dictionary(uniqueKeysWithValues: pairs.map { ($0.id, ["type": "noul", "noul": 0.9] as [String: Any]) })
    let body = try JSONSerialization.data(withJSONObject: ["result": ["answers": answers]])
    let transport = FixtureTransport([HTTPResponse(data: body, status: 200)])
    let scores = try await ClefClient(credentials: testCredentials, transport: transport).relatedness(inputs, pairs: pairs)
    #expect(scores.count == 64)
    let requests = await transport.requests
    let data = try #require(requests.first?.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let images = try #require(json["images"] as? [String])
    #expect(images.count == 4)
    let state = try #require(json["state"] as? [[String: Any]])
    let last = try #require(state.first { $0["id"] as? Int == 49 })
    #expect(last["previewImageIndex"] as? Int == 3)
    #expect(last["previewCellIndex"] as? Int == 1)
    #expect(last["previewColumns"] as? Int == 2)
    for url in images {
        let encoded = try #require(url.split(separator: ",").last)
        let data = try #require(Data(base64Encoded: String(encoded)))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width <= 768 && image.height <= 768)
    }
}

@Test func extractorProducesSmallImagePreviews() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("image.png")
    try tinyPNG().write(to: url)
    let file = try FileIntake.describe(url)
    let extracted = try await ContentExtractor().extract(file)
    let preview = try #require(extracted.preview)
    #expect(preview.count < 300_000)
    let source = try #require(CGImageSourceCreateWithData(preview as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width <= 512 && image.height <= 512)
}

@Test func pdfTextIsExtractedLocally() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("travel.pdf")
    var page = CGRect(x: 0, y: 0, width: 300, height: 200)
    let context = try #require(CGContext(url as CFURL, mediaBox: &page, nil))
    context.beginPDFPage(nil)
    context.textPosition = CGPoint(x: 20, y: 100)
    let attributes = [kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 14, nil)]
    let text = NSAttributedString(string: "Travel itinerary for Kyoto", attributes: attributes)
    CTLineDraw(CTLineCreateWithAttributedString(text), context)
    context.endPDFPage(); context.closePDF()
    let extracted = try await ContentExtractor().extract(FileIntake.describe(url))
    #expect(extracted.excerpt.contains("Kyoto"))
}

@Test func richTextIsExtractedWithoutUploadingTheDocument() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("budget.rtf")
    let text = NSAttributedString(string: "Project budget and invoice planning")
    let rtf = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    try rtf.write(to: url)
    let extracted = try await ContentExtractor().extract(FileIntake.describe(url))
    #expect(extracted.excerpt.contains("budget"))
    #expect(extracted.preview == nil)
}
