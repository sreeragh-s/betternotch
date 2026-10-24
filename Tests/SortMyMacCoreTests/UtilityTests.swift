import AppKit
import AVFoundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
import ZIPFoundation
@testable import SortMyMacCore

private func utilityImage(_ url: URL, width: Int = 400, height: Int = 200) throws {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0.3, blue: 0.2, alpha: 0.5)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = context.makeImage()!, destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil); #expect(CGImageDestinationFinalize(destination))
}
private func utilityAudio(_ url: URL, seconds: Double = 3) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(48_000 * seconds))!
    buffer.frameLength = buffer.frameCapacity
    for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 440 * 2 * .pi / 48_000) * 0.2) }
    try file.write(from: buffer)
}
@Test func utilityLibraryPersistsIndependentMeetingsAndShelfAcrossConnections() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("library.sqlite")
    let store = try LibraryStore(url: url)
    var first = MeetingRecord(title: "Planning"), second = MeetingRecord(title: "Design")
    first.segments = [TranscriptSegment(start: 1, end: 3, text: "Ship the image editor")]
    second.segments = [TranscriptSegment(start: 4, end: 6, text: "Review recording quality")]
    try await store.save(first, category: "meetings", id: first.id.uuidString)
    try await store.save(second, category: "meetings", id: second.id.uuidString)
    let reopened = try LibraryStore(url: url)
    let meetings = try await reopened.list(MeetingRecord.self, category: "meetings")
    #expect(meetings.count == 2); #expect(Set(meetings.map(\.title)) == ["Planning", "Design"])
    #expect(meetings.first { $0.id == first.id }?.segments.first?.text == "Ship the image editor")
    try await reopened.remove(category: "meetings", id: first.id.uuidString)
    #expect(try await store.list(MeetingRecord.self, category: "meetings").count == 1)
}
@Test func utilityActionsUseCompatibleSubsetsAndRankMergeFirst() {
    func descriptor(_ name: String, _ type: String) -> FileDescriptor { FileDescriptor(url: URL(fileURLWithPath: "/tmp/" + name), size: 10, modified: .distantPast, typeIdentifier: type) }
    let files = [descriptor("a.pdf", "com.adobe.pdf"), descriptor("b.pdf", "com.adobe.pdf"), descriptor("c.png", "public.png")]
    let actions = FileActionDefinition.available(for: files)
    #expect(actions.first?.kind == .mergePDF)
    #expect(actions.first?.inputs.count == 2)
    #expect(actions.first { $0.kind == .resize }?.inputs.count == 1)
    #expect(actions.first { $0.kind == .zip }?.inputs.count == 3)
    #expect(!actions.contains { $0.kind == .trim })
}
@Test func utilityImagePreviewPreservesOriginalAndPublishesValidatedDimensions() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("image.png"); try utilityImage(source)
    let bytes = try Data(contentsOf: source), file = try FileIntake.describe(source)
    var settings = ActionSettings(); settings.width = 100; settings.format = "png"
    let result = try await ActionExecutor(root: root).execute(ActionRequest(kind: .resize, inputs: [file], settings: settings)) { _, _, _ in }
    #expect(result.outputs.count == 1); #expect(try Data(contentsOf: source) == bytes)
    let imageSource = CGImageSourceCreateWithURL(result.outputs[0] as CFURL, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)! as NSDictionary
    #expect(properties[kCGImagePropertyPixelWidth] as? Int == 100)
    #expect(properties[kCGImagePropertyPixelHeight] as? Int == 50)
    #expect(result.outputs[0].path.contains("/Outputs/"))
}
@Test func utilityUnreachableImageTargetDoesNotPublishBrokenOutput() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("image.png"); try utilityImage(source)
    var settings = ActionSettings(); settings.format = "png"; settings.targetBytes = 1
    let request = ActionRequest(kind: .compressImage, inputs: [try FileIntake.describe(source)], settings: settings)
    await #expect(throws: (any Error).self) { try await ActionExecutor(root: root).execute(request) { _, _, _ in } }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Outputs/\(request.id.uuidString)").path))
    #expect(FileManager.default.fileExists(atPath: source.path))
}
@Test func utilityPDFPageOrderAndAnnotationsSurviveEditing() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("source.pdf")
    let document = PDFDocument()
    for index in 0..<3 {
        let imageURL = root.appendingPathComponent("page-\(index).png")
        try utilityImage(imageURL, width: 200, height: 300)
        let image = NSImage(contentsOf: imageURL)!
        let page = PDFPage(image: image)!
        page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 5, y: 5, width: 50, height: 20), forType: .text, withProperties: nil))
        page.rotation = index * 90; document.insert(page, at: index)
    }
    #expect(document.write(to: url))
    var settings = ActionSettings(); settings.pages = "3,1"; settings.rotation = 90
    let result = try await ActionExecutor(root: root).execute(ActionRequest(kind: .editPDF, inputs: [try FileIntake.describe(url)], settings: settings)) { _, _, _ in }
    let output = PDFDocument(url: result.outputs[0])!
    #expect(output.pageCount == 2); #expect(output.page(at: 0)?.rotation == 270); #expect(output.page(at: 1)?.rotation == 90)
    #expect(output.page(at: 0)?.annotations.count == PDFDocument(url: url)?.page(at: 2)?.annotations.count)
    #expect(try PDFProcessor.pageIndices("2-3,1", count: 3) == [1, 2, 0])
    #expect(throws: (any Error).self) { try PDFProcessor.pageIndices("0,5", count: 3) }
}
@Test func utilityZIPRoundTripAndBoundedExtraction() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("notes.txt"); try Data("hello world".utf8).write(to: url)
    let result = try await ActionExecutor(root: root).execute(ActionRequest(kind: .zip, inputs: [try FileIntake.describe(url)], settings: ActionSettings())) { _, _, _ in }
    let entries = try ActionExecutor.archiveContents(result.outputs[0]); #expect(entries.map(\.path) == ["notes.txt"])
    let destination = root.appendingPathComponent("unpacked")
    try ActionExecutor.extractZIP(result.outputs[0], to: destination)
    #expect(try String(contentsOf: destination.appendingPathComponent("notes.txt"), encoding: .utf8) == "hello world")
    #expect(throws: (any Error).self) { try ActionExecutor.extractZIP(result.outputs[0], to: root.appendingPathComponent("too-large"), maximumBytes: 2) }
}
@Test func utilityZIPRejectsPathTraversalBeforeCreatingDestination() throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let zip = root.appendingPathComponent("unsafe.zip"), archive = try Archive(url: zip, accessMode: .create)
    let bytes = Data("unsafe".utf8)
    try archive.addEntry(with: "../escaped.txt", type: .file, uncompressedSize: Int64(bytes.count), provider: { position, size in bytes.subdata(in: Int(position)..<min(bytes.count, Int(position) + size)) })
    let destination = root.appendingPathComponent("output")
    #expect(throws: (any Error).self) { try ActionExecutor.extractZIP(zip, to: destination) }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.txt").path))
}
@Test func utilityRenameUndoPreservesContentsAndOccupiedOriginals() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("note.txt"); try Data("original".utf8).write(to: original)
    let store = try LibraryStore(url: root.appendingPathComponent("library.sqlite")), coordinator = RenameCoordinator(store: store)
    var settings = ActionSettings(); settings.prefix = "meeting-"
    let record = try await coordinator.apply([FileIntake.describe(original)], settings: settings)
    #expect(record.status == "completed"); #expect(!FileManager.default.fileExists(atPath: original.path))
    try Data("new user file".utf8).write(to: original)
    await #expect(throws: (any Error).self) { try await coordinator.undo(record) }
    #expect(try String(contentsOf: original, encoding: .utf8) == "new user file")
    try FileManager.default.removeItem(at: original)
    let stored = try await store.list(RenameRecord.self, category: "renames")[0]
    let restored = try await coordinator.undo(stored)
    #expect(restored.status == "undone"); #expect(try String(contentsOf: original, encoding: .utf8) == "original")
}
@Test func utilityTranscriptFormatsAndOverlapDeduplication() {
    var meeting = MeetingRecord(title: "Review")
    meeting.segments = [TranscriptSegment(start: 1.25, end: 3.5, text: "Ship it")]
    #expect(TranscriptExporter.text(meeting, format: "srt").contains("00:00:01,250 --> 00:00:03,500"))
    #expect(TranscriptExporter.text(meeting, format: "vtt").hasPrefix("WEBVTT"))
    #expect(TranscriptExporter.deduplicated("we should ship today", previous: "I think we should") == "ship today")
    #expect(TranscriptExporter.deduplicated("new topic", previous: "") == "new topic")
}
@Test func utilityTrimExportsSelectedAudioInterval() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.caf"); try utilityAudio(source)
    var settings = ActionSettings(); settings.start = 0.5; settings.end = 2; settings.format = "m4a"
    let output = root.appendingPathComponent("trimmed.m4a")
    try await MediaProcessor.render(source, kind: .trim, settings: settings, to: output)
    let info = try await MediaProcessor.info(output)
    #expect(abs(info.duration - 1.5) < 0.1); #expect(info.hasAudio); #expect(!info.hasVideo)
    settings.start = 2; settings.end = 1
    #expect(throws: (any Error).self) { try MediaProcessor.range(settings: settings, duration: 3) }
}
@Test func utilityMeetingAssemblyPreservesSourceOffsets() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("audio.caf"); try utilityAudio(source, seconds: 1)
    var meeting = MeetingRecord(title: "Offset test")
    meeting.chunks = [AudioChunk(source: .microphone, url: source, start: 0, duration: 1), AudioChunk(source: .system, url: source, start: 2, duration: 1)]
    let output = try await MeetingAudio.finalize(meeting, root: root)
    let info = try await MediaProcessor.info(output)
    #expect(abs(info.duration - 3) < 0.1)
}
@Test func utilityScreenshotOnlyGroupingWorksWithEmptyCredentials() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Screenshot 2026-10-25 at 12.30.10 PM.png"); try utilityImage(source)
    let transport = FixtureTransport([HTTPResponse(data: Data(), status: 401)])
    let service = ClefGroupingService(client: ClefClient(credentials: CloudflareCredentials(accountID: "", token: ""), transport: transport))
    let plan = try await service.group([FileIntake.describe(source)]) { _ in }
    #expect(plan.groups.first?.name == "Screenshots"); #expect(await transport.requests.isEmpty)
}
@Test func utilityEditorGeometryStaysInsideAvailableDisplay() {
    let screen = CGRect(x: -1280, y: 0, width: 1280, height: 800)
    let geometry = NotchGeometry(screen: screen, safeTop: 38, editor: true, availableHeight: 760)
    #expect(geometry.expandedSize.width <= 960); #expect(geometry.expandedSize.height <= 696)
    #expect(geometry.expandedFrame.maxY == screen.maxY)
}

@Test func utilityPipelineRunsEveryStepAndRemovesIntermediateOutputs() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.png"); try utilityImage(source)
    var resize = ActionSettings(); resize.width = 80; resize.format = "png"
    var convert = ActionSettings(); convert.format = "jpeg"
    let steps = [ActionRequest(kind: .resize, inputs: [], settings: resize), ActionRequest(kind: .convertImage, inputs: [], settings: convert)]
    let id = UUID()
    let result = try await ActionExecutor(root: root).executePipeline(id: id, steps: steps, inputs: [try FileIntake.describe(source)]) { _, _, _ in }
    #expect(result.outputs.count == 1); #expect(result.outputs[0].pathExtension == "jpg")
    let image = CGImageSourceCreateWithURL(result.outputs[0] as CFURL, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil)! as NSDictionary
    #expect(properties[kCGImagePropertyPixelWidth] as? Int == 80)
    let directories = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Outputs").path)
    #expect(directories == [id.uuidString])
}
@Test func utilitySplitPDFCreatesOneOutputPerSelectedPage() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let imageURL = root.appendingPathComponent("page.png"); try utilityImage(imageURL)
    let document = PDFDocument()
    for _ in 0..<3 { document.insert(PDFPage(image: NSImage(contentsOf: imageURL)!)!, at: document.pageCount) }
    let source = root.appendingPathComponent("pages.pdf"); #expect(document.write(to: source))
    var settings = ActionSettings(); settings.pages = "3,1"; settings.splitPages = true
    let result = try await ActionExecutor(root: root).execute(ActionRequest(kind: .editPDF, inputs: [try FileIntake.describe(source)], settings: settings)) { _, _, _ in }
    #expect(result.outputs.count == 2)
    #expect(result.outputs.allSatisfy { PDFDocument(url: $0)?.pageCount == 1 })
}
@Test func utilityDestinationCopyNumbersCollisionsAndPreservesSource() throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("destination"); try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("notes.txt"); try Data("original".utf8).write(to: source)
    try Data("existing".utf8).write(to: destination.appendingPathComponent("notes.txt"))
    let outputs = try DestinationCopy.copy([FileIntake.describe(source)], into: destination)
    #expect(outputs[0].lastPathComponent == "notes 2.txt")
    #expect(try String(contentsOf: outputs[0], encoding: .utf8) == "original")
    #expect(try String(contentsOf: source, encoding: .utf8) == "original")
    #expect(try String(contentsOf: destination.appendingPathComponent("notes.txt"), encoding: .utf8) == "existing")
}
@Test func utilityTextToPDFProducesSelectableText() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("notes.txt"); try Data("Meeting decisions\nShip the native tools.".utf8).write(to: source)
    let result = try await ActionExecutor(root: root).execute(ActionRequest(kind: .makePDF, inputs: [try FileIntake.describe(source)], settings: ActionSettings())) { _, _, _ in }
    let document = try #require(PDFDocument(url: result.outputs[0]))
    #expect(document.string?.contains("Meeting decisions") == true)
}

private func utilityVideo(_ url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 96])
    input.transform = CGAffineTransform(rotationAngle: .pi / 2)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 96])
    writer.add(input); #expect(writer.startWriting()); writer.startSession(atSourceTime: .zero)
    for index in 0..<80 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer) == kCVReturnSuccess)
        CVPixelBufferLockBaseAddress(buffer!, [])
        memset(CVPixelBufferGetBaseAddress(buffer!)!, Int32(index * 3), CVPixelBufferGetDataSize(buffer!))
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        #expect(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(index), timescale: 20)))
    }
    input.markAsFinished(); await writer.finishWriting()
    #expect(writer.status == .completed)
}
@Test func utilityVideoTrimPreservesPortraitOrientationAndSelectedDuration() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("portrait.mov"); try await utilityVideo(source)
    var settings = ActionSettings(); settings.format = "mp4"; settings.start = 0.5; settings.end = 2.5
    let output = root.appendingPathComponent("trim.mp4")
    try await MediaProcessor.render(source, kind: .trim, settings: settings, to: output)
    let info = try await MediaProcessor.info(output)
    #expect(info.hasVideo); #expect(!info.hasAudio); #expect(info.height > info.width)
    #expect(abs(info.duration - 2) <= 0.05)
    settings.format = "m4a"
    await #expect(throws: (any Error).self) { try await MediaProcessor.render(source, kind: .extractAudio, settings: settings, to: root.appendingPathComponent("missing.m4a")) }
}
@Test func utilityGIFUsesBoundedSelectedFrames() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("video.mov"); try await utilityVideo(source)
    var settings = ActionSettings(); settings.start = 1; settings.end = 2
    let output = root.appendingPathComponent("clip.gif")
    try await MediaProcessor.render(source, kind: .makeGIF, settings: settings, to: output)
    let image = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
    #expect(CGImageSourceGetCount(image) == 10)
}
@Test func utilityCanceledActionNeverPublishesAnOutput() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("image.png"); try utilityImage(source)
    let request = ActionRequest(kind: .resize, inputs: [try FileIntake.describe(source)], settings: ActionSettings())
    let task = Task { try await ActionExecutor(root: root).execute(request) { _, _, _ in } }; task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Outputs/\(request.id.uuidString)").path))
    #expect(FileManager.default.fileExists(atPath: source.path))
}
@Test func utilityShelfRejectsAReplacedFileIdentity() throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("notes.txt"); try Data("first".utf8).write(to: source)
    let item = ShelfItem(file: try FileIntake.describe(source))
    // Keep the original inode alive elsewhere, then replace the path with another file.
    let moved = root.appendingPathComponent("moved.txt"); try FileManager.default.moveItem(at: source, to: moved)
    try Data("other".utf8).write(to: source)
    let resolved = item.resolvedURL()
    #expect(resolved == nil || resolved == moved)
    #expect(resolved != source)
}

@Test func utilityImageRotationDoesNotAddExtraPixels() throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.png"); try utilityImage(source, width: 400, height: 200)
    let output = root.appendingPathComponent("rotated.png")
    var settings = ActionSettings(); settings.format = "png"; settings.rotation = 90
    try ImageProcessor.render(FileIntake.describe(source), kind: .cropImage, settings: settings, to: output)
    let image = CGImageSourceCreateWithURL(output as CFURL, nil)!
    let values = CGImageSourceCopyPropertiesAtIndex(image, 0, nil)! as NSDictionary
    #expect(values[kCGImagePropertyPixelWidth] as? Int == 200); #expect(values[kCGImagePropertyPixelHeight] as? Int == 400)
}
@Test func utilityDraggedCropExportsTheSelectedPixelsAfterRotation() throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("quarters.png")
    // Image data is top-down: each corner has a different color so an inverted
    // canvas/export coordinate or rotation cannot pass by dimensions alone.
    let width = 800, height = 500
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height { for x in 0..<width {
        let offset = (y * width + x) * 4
        let color: [UInt8] = y < height / 2 ? (x < width / 2 ? [255, 0, 0] : [0, 255, 0]) : (x < width / 2 ? [0, 0, 255] : [255, 255, 0])
        for channel in 0..<3 { pixels[offset + channel] = color[channel] }
    } }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil); #expect(CGImageDestinationFinalize(destination))
    let selection = CropSelection(x: 0.1, y: 0.1, width: 0.3, height: 0.3).aligned(to: CGSize(width: width, height: height))
    for rotation in [0, 90, 180, 270] {
        let displayed = selection.rotated(clockwise: rotation)
        let crop = displayed.rotated(clockwise: -rotation)
        var settings = ActionSettings(); settings.format = "png"; settings.rotation = rotation
        settings.cropX = crop.x; settings.cropY = 1 - crop.maxY; settings.cropWidth = crop.width; settings.cropHeight = crop.height
        let output = root.appendingPathComponent("crop-\(rotation).png")
        try ImageProcessor.render(FileIntake.describe(source), kind: .cropImage, settings: settings, to: output)
        let rendered = try #require(NSBitmapImageRep(data: Data(contentsOf: output)))
        #expect(rendered.pixelsWide == (rotation % 180 == 0 ? 240 : 150))
        #expect(rendered.pixelsHigh == (rotation % 180 == 0 ? 150 : 240))
        let color = try #require(rendered.colorAt(x: rendered.pixelsWide / 2, y: rendered.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        // Allow color-management differences while distinguishing every quadrant.
        #expect(color.redComponent > 0.9); #expect(color.greenComponent < 0.2); #expect(color.blueComponent < 0.2)
    }
}
@Test func utilityRecordingStatusHasSpaceOutsideThePhysicalCutout() {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let normal = NotchGeometry(screen: screen, safeTop: 38, leftWidth: 661, rightWidth: 661)
    let recording = NotchGeometry(screen: screen, safeTop: 38, leftWidth: 661, rightWidth: 661, activity: true)
    #expect(recording.restingSize.width == normal.restingSize.width + 144)
    #expect(recording.restingFrame.midX == normal.restingFrame.midX)
}
