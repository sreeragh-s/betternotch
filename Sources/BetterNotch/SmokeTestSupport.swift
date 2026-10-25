#if DEBUG
import AppKit
import BetterNotchCore

/// Explicit development-only mode. All fixtures and recovery history live under a fresh temporary directory.
@MainActor
enum SmokeTestSupport {
    static func configure(_ model: AppModel, root: URL) throws {
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        guard canonical.path.hasPrefix("/private/tmp/BetterNotch-QA-") || canonical.path.hasPrefix("/tmp/BetterNotch-QA-") else {
            throw SortError.message("Smoke test directory must be a fresh /tmp/BetterNotch-QA-* directory.")
        }
        guard try LocalFileOperations().reserveDirectory(canonical) else {
            throw SortError.message("Smoke test directory already exists. Choose a new path.")
        }
        // App-local appearance previews never change the user's macOS preferences.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--smoke-appearance"), arguments.indices.contains(index + 1) {
            switch arguments[index + 1] {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: break
            }
        }
        let sources = canonical.appendingPathComponent("sources", isDirectory: true)
        let destination = canonical.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let fixture: [(String, String)] = [
            ("Travel-flight.txt", "Travel to Kyoto. Flight itinerary and airport transfer for the autumn trip."),
            ("Travel-hotel.txt", "Travel to Kyoto. Hotel booking and check-in details for the autumn trip."),
            ("Invoices-design.txt", "Design project invoice. Client billing, payment details, and services delivered."),
            ("Invoices-payment.txt", "Design project invoice payment receipt and client billing confirmation.")
        ]
        let urls = try fixture.map { name, text in
            let url = sources.appendingPathComponent(name)
            try Data(text.utf8).write(to: url, options: .withoutOverwriting)
            return url
        }
        model.moves = MoveCoordinator(journalURL: canonical.appendingPathComponent("history/moves.json"))
        model.pinOpenForSmokeTest = true
        model.fixtureGroupingService = SmokeGroupingService()
        model.receive(urls)
        model.status = "UI test files · no Cloudflare requests · \(canonical.lastPathComponent)"
        model.showNotch()
    }
}

private struct SmokeGroupingService: GroupingService {
    func group(_ files: [FileDescriptor], progress: @escaping @Sendable (GroupingProgress) async -> Void) async throws -> GroupingPlan {
        let evidence = files.sorted { $0.name < $1.name }.map { FileEvidence(file: $0) }
        var scores: [PairKey: Double] = [:]
        for a in evidence.indices {
            for b in evidence.indices where b > a {
                scores[PairKey(a, b)] = evidence[a].file.name.split(separator: "-").first == evidence[b].file.name.split(separator: "-").first ? 0.96 : 0.05
            }
        }
        await progress(GroupingProgress("Reading disposable UI fixtures…", completed: 1, total: 2))
        try await Task.sleep(for: .seconds(1))
        let plan = TopicClusterer.plan(evidence, scores: scores)
        await progress(GroupingProgress("Gathering related files…", completed: 2, total: 2, plan: plan))
        try await Task.sleep(for: .seconds(1))
        return plan
    }
}

#endif

#if DEBUG
import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

extension SmokeTestSupport {
    static func populateHub(_ model: AppModel, root: URL) async throws {
        let hub = model.hub
        let sources = root.appendingPathComponent("sources")
        let imageURL = sources.appendingPathComponent("Preview-image.png")
        let context = CGContext(data: nil, width: 800, height: 500, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.05, green: 0.1, blue: 0.25, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 1, alpha: 1)); context.fillEllipse(in: CGRect(x: 200, y: 100, width: 300, height: 300))
        let image = context.makeImage()!, destination = CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil); CGImageDestinationFinalize(destination)
        let audioURL = sources.appendingPathComponent("Preview-audio.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        do {
            let writer = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
            buffer.frameLength = 48000
            for second in 0..<30 {
                for index in 0..<48000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * (220 + Double(second) * 10) * 2 * .pi / 48000) * 0.15) }
                try writer.write(from: buffer)
            }
        }
        let pdfURL = sources.appendingPathComponent("Preview-pages.pdf")
        let document = PDFDocument()
        for _ in 0..<3 { document.insert(PDFPage(image: NSImage(cgImage: image, size: .zero))!, at: document.pageCount) }
        document.write(to: pdfURL)
        let originalSelection = hub.selection
        hub.add([imageURL, audioURL, pdfURL]); hub.selection = originalSelection
        var meeting = MeetingRecord(title: "UI fixture · no real meeting recorded", source: .microphone)
        meeting.status = .ready; meeting.audioURL = audioURL; meeting.duration = 30
        meeting.transcriptStatus = "Fixture transcript"
        meeting.segments = [TranscriptSegment(start: 0, end: 5, text: "Review the image previews and file actions.", source: .microphone), TranscriptSegment(start: 12, end: 18, text: "Check that trim settings match the exported interval.", source: .system)]
        hub.meetings.append(meeting); hub.persistMeeting(meeting)
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--smoke-model"), arguments.indices.contains(index + 1) {
            let target = try UtilityPaths.directory("Models", root: hub.root).appendingPathComponent("ggml-base.bin")
            try FileManager.default.linkItem(at: URL(fileURLWithPath: arguments[index + 1]), to: target)
            hub.installedModels.insert("base"); hub.speechModel = "base"
        }
        if let index = arguments.firstIndex(of: "--smoke-transcribe"), arguments.indices.contains(index + 1) {
            hub.editorInputs = [try FileIntake.describe(URL(fileURLWithPath: arguments[index + 1]))]
            hub.importMeetings()
            return
        }
        let routeIndex = arguments.firstIndex(of: "--smoke-route")
        let route = routeIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "files"
        switch route {
        case "native-promise":
            model.receiveForOrganization(model.files.map(\.url))
            await model.organizationStageTask?.value
            await model.organizationTask?.value
            model.notch?.showNativePromiseTest(destination: root.appendingPathComponent("destination"))
        case "empty-organize": model.clear(); hub.route = .organize
        case "organize-completed":
            model.clear(); model.phase = .completed; model.exportMovedCount = 2; model.exportCopiedCount = 2; hub.route = .organize
        case "drop", "drop-organize":
            hub.route = .home; model.dragFileCount = 4; model.dropTargeted = true
            model.dropChoice = route == "drop-organize" ? .organize : nil
        case "organize":
            model.receiveForOrganization(model.files.map(\.url))
        case "codex", "codex-question", "codex-diff", "codex-approval":
            let codex = hub.codex
            codex.setEnabled(true)
            let questionData = try JSONSerialization.data(withJSONObject: ["hook_event_name": "PreToolUse", "session_id": UUID().uuidString, "turn_id": "qa", "cwd": sources.path, "tool_name": "request_user_input", "tool_input": ["questions": [["id": "format", "header": "Format", "question": "Which format should I use for the exported images?", "options": [["label": "PNG (Recommended)", "description": "Keep transparency and full image quality."], ["label": "JPEG", "description": "Create a smaller file for sharing."]]]]]])
            let question = try CodexEvent.hook(questionData, questionCallID: "call-ui-test")!
            let diff = CodexEvent(kind: .approval, threadID: question.threadID, project: sources.path, title: "Review changes · UI fixture only", message: "No action will run.", diff: "*** Begin Patch\n*** Update File: Sources/Export.swift\n@@\n- let format = .jpeg\n+ let format = .png\n+ let preserveTransparency = true\n*** End Patch", expiresAt: Date().addingTimeInterval(90))
            let permission = CodexEvent(kind: .approval, threadID: question.threadID, project: sources.path, title: "Allow project checks?", message: "UI fixture only. No command will run.", command: "swift test", expiresAt: Date().addingTimeInterval(90))
            codex.ingest(route == "codex-question" ? [question] : route == "codex-diff" ? [diff] : route == "codex-approval" ? [permission] : [question, permission])
            codex.selectedID = route == "codex-question" ? question.id : route == "codex-diff" ? diff.id : route == "codex-approval" ? permission.id : nil
            hub.route = route == "codex-diff" ? .codexDiff : .codex
        case "home": hub.route = .home
        case "home-error": hub.route = .home; hub.error = "Recording could not start. Allow Screen & System Audio Recording in System Settings, then try again."
        case "permissions": model.settingsPage = "Permissions"; model.notch?.collapse(force: true); model.showSettings()
        case "recording": hub.route = .recordingSetup
        case "meeting-list": hub.route = .meetings
        case "empty-meetings": hub.meetings = []; hub.route = .meetings
        case "crop": hub.open(FileActionDefinition.available(for: [try FileIntake.describe(imageURL)]).first { $0.kind == .cropImage }!)
        case "images": hub.open(FileActionDefinition.available(for: [try FileIntake.describe(imageURL)]).first { $0.kind == .resize }!)
        case "media": hub.open(FileActionDefinition.available(for: [try FileIntake.describe(audioURL)]).first { $0.kind == .trim }!)
        case "pdf": hub.open(FileActionDefinition.available(for: [try FileIntake.describe(pdfURL)]).first { $0.kind == .editPDF }!)
        case "meetings": hub.openMeeting(meeting)
        case "models": hub.route = .models
        default: hub.route = .fileActions
        }
    }
}
#endif
