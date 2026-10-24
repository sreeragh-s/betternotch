import Darwin
import Foundation
import Testing
@testable import SortMyMacCore

private func screenshotEvidence(_ name: String) -> FileEvidence {
    FileEvidence(file: FileDescriptor(url: URL(fileURLWithPath: "/tmp/\(name)"), size: 20,
                                     modified: .distantPast, typeIdentifier: "public.png"), isScreenshot: true)
}

@Test func recognizesCaptureNamesWithoutTreatingEveryImageAsAScreenshot() {
    for name in ["Screenshot 2026-10-03 at 1.56.26\u{202F}AM.png",
                 "Screen Shot 2020-01-02 at 13.04.05.png",
                 "screenshot_2026-10-24_08.21.45.png",
                 "Screenshot 2026-10-24 at 8.21.45 PM (2).png"] {
        #expect(ScreenshotDetector.isScreenshot(screenshotEvidence(name).file))
    }
    for name in ["holiday.png", "Screenshot tutorial.png", "Screenshot.png", "my screenshot project.png",
                 "Screenshot 2026-10-24 at 8.21.45 PM edited poster.png"] {
        #expect(!ScreenshotDetector.isScreenshot(screenshotEvidence(name).file))
    }
    #expect(!ScreenshotDetector.isScreenshot(evidence("Screenshot 2026-10-24 at 8.21.45 PM.txt").file))
}

@Test func captureMetadataRecognizesRenamedScreenshotsWithoutDecodingOrChangingThem() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let image = try tinyPNG()
    let url = root.appendingPathComponent("Renamed capture.png")
    try image.write(to: url)
    for value in [true, false] {
        let attribute = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        let result = attribute.withUnsafeBytes {
            setxattr(url.path, ScreenshotDetector.captureAttribute, $0.baseAddress, $0.count, 0, 0)
        }
        #expect(result == 0)
        let extracted = try await ContentExtractor().extract(FileIntake.describe(url))
        #expect(extracted.isScreenshot == value)
        #expect((extracted.preview == nil) == value)
        #expect(try Data(contentsOf: url) == image)
    }
}

@Test func capturesStayTogetherDespiteUnrelatedVisualTopicsAndLowAIScores() {
    let captures = [screenshotEvidence("Screenshot 2026-10-02 at 6.38.31 PM.png"),
                    screenshotEvidence("Screenshot 2026-10-24 at 8.21.45 PM.png"),
                    screenshotEvidence("Renamed capture.png")]
    let inputs = captures + [evidence("travel-flight.txt"), evidence("travel-hotel.txt"), evidence("unknown.txt")]
    let plan = TopicClusterer.plan(inputs, scores: [PairKey(0, 1): 0.1, PairKey(1, 2): 0.95,
                                                  PairKey(2, 3): 0.99, PairKey(3, 4): 0.95])
    #expect(plan.groups.map(\.name) == ["Screenshots", "Travel", "Other"])
    #expect(plan.groups[0].files == captures.map(\.file))
    #expect(Set(plan.groups.flatMap(\.files).map(\.id)) == Set(inputs.map(\.file.id)))
    #expect(plan.groups.flatMap(\.files).count == inputs.count)
    #expect(TopicClusterer.plan(inputs, scores: [PairKey(3, 4): 0.95]) == plan)
    #expect(TopicClusterer.plan([captures[0]], scores: [:], includeUncertain: false).groups.first?.name == "Screenshots")
}

@Test func screenshotOnlySessionsNeedNoCloudflareRequestsAndLeaveSourcesUnchanged() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let image = try tinyPNG()
    let files = try (0..<50).map { index in
        let url = root.appendingPathComponent(String(format: "Screenshot 2026-10-24 at 8.21.%02d PM.png", index))
        try image.write(to: url)
        return try FileIntake.describe(url)
    }
    let transport = FixtureTransport([HTTPResponse(data: Data(), status: 403)])
    let service = ClefGroupingService(client: ClefClient(credentials: testCredentials, transport: transport))
    let plan = try await service.group(files) { _ in }
    #expect(await transport.requests.isEmpty)
    #expect(plan.groups.count == 1)
    #expect(plan.groups[0].name == "Screenshots")
    #expect(plan.groups[0].files.count == 50)
    for file in files { #expect(try Data(contentsOf: file.url) == image) }
    let canceled = Task {
        try Task.checkCancellation()
        return try await service.group(files) { _ in }
    }
    canceled.cancel()
    await #expect(throws: CancellationError.self) { try await canceled.value }
}

@Test func mixedSessionSendsOnlyRemainingTopicFilesToClef() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let names = ["Screenshot 2026-10-02 at 6.38.31 PM.png", "Screenshot 2026-10-24 at 8.21.45 PM.png",
                 "travel-flight.txt", "travel-hotel.txt"]
    let files = try names.map { name in
        let url = root.appendingPathComponent(name)
        let data = name.hasSuffix(".png") ? try tinyPNG() : Data("Travel Kyoto itinerary".utf8)
        try data.write(to: url)
        return try FileIntake.describe(url)
    }
    let response = Data(#"{"result":{"answers":{"pair_2_3":{"type":"noul","noul":0.95}}}}"#.utf8)
    let transport = FixtureTransport([HTTPResponse(data: response, status: 200)])
    let service = ClefGroupingService(client: ClefClient(credentials: testCredentials, transport: transport))
    let plan = try await service.group(files.reversed()) { _ in }
    #expect(plan.groups.count == 2)
    #expect(plan.groups[0].name == "Screenshots")
    #expect(plan.groups.allSatisfy { $0.files.count == 2 })
    let requests = await transport.requests
    #expect(requests.count == 1)
    let body = try #require(requests.first?.httpBody)
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let records = try #require(payload["state"] as? [[String: Any]])
    #expect(records.compactMap { $0["name"] as? String }.sorted() == ["travel-flight.txt", "travel-hotel.txt"])
    #expect(payload["images"] == nil)
    #expect((payload["questions"] as? [String: Any])?.count == 1)
}
