import Foundation
import Testing
@testable import SortMyMacCore

func evidence(_ name: String, preview: Data? = nil) -> FileEvidence {
    FileEvidence(file: FileDescriptor(url: URL(fileURLWithPath: "/tmp/\(name)"), size: 20,
                                     modified: .distantPast, typeIdentifier: "public.plain-text"), preview: preview)
}

actor FixtureTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let responses: [HTTPResponse]
    init(_ responses: [HTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return responses[min(requests.count - 1, responses.count - 1)]
    }
}

let testCredentials = CloudflareCredentials(accountID: String(repeating: "a", count: 32), token: "fixture-token")

@Test func completeLinkDoesNotMergeIndirectRelationships() {
    let inputs = [evidence("travel-flight.txt"), evidence("travel-hotel.txt"), evidence("tax-return.txt")]
    let scores = [PairKey(0, 1): 0.95, PairKey(1, 2): 0.85, PairKey(0, 2): 0.2]
    let plan = TopicClusterer.plan(inputs, scores: scores)
    #expect(plan.groups.count == 2)
    #expect(plan.groups[0].files.map(\.name) == ["travel-flight.txt", "travel-hotel.txt"])
    #expect(plan.groups[0].name == "Travel")
    #expect(plan.groups[1].name == "Other")
    #expect(TopicClusterer.plan(inputs, scores: scores) == plan)
}

@Test func unknownAndUncertainEdgesNeverGroupFiles() {
    let inputs = [evidence("a.txt"), evidence("b.txt"), evidence("c.txt")]
    #expect(TopicClusterer.plan(inputs, scores: [PairKey(0, 1): 0.79]).groups[0].name == "Other")
    #expect(TopicClusterer.plan(inputs, scores: [:], includeUncertain: false).groups.isEmpty)
}

@Test func batchesRespectQuestionAndImageLimitsAndCoverEveryPair() {
    let inputs = (0..<50).map { evidence("item\($0).jpg", preview: Data([1, 2, 3])) }
    let batches = ClefGroupingService.batches(inputs)
    let pairs = batches.flatMap { $0 }
    #expect(pairs.count == 1_225)
    #expect(Set(pairs).count == pairs.count)
    for batch in batches {
        #expect(batch.count <= 64)

    }
    let textBatches = ClefGroupingService.batches((0..<50).map { evidence("file\($0).txt") })
    #expect(textBatches.count == 20)
}

@Test func decodesCloudflareEnvelopeAndRejectsMissingOrInvalidDecisions() throws {
    let body = Data(#"{"success":true,"result":{"answers":{"q":{"type":"noul","noul":0.93}}}}"#.utf8)
    #expect(try ClefClient.decode(body, expected: ["q"]) == ["q": 0.93])
    for invalid in [#"{"answers":{}}"#, #"{"answers":{"q":{"type":"noul","noul":1.2}}}"#, #"{"answers":{"q":0.8}}"#, #"{"success":false}"#, "not-json"] {
        #expect(throws: (any Error).self) { try ClefClient.decode(Data(invalid.utf8), expected: ["q"]) }
    }
}

@Test func requestUsesDocumentedPayloadAndRetriesTransientErrors() async throws {
    let good = Data(#"{"result":{"answers":{"pair_0_1":{"type":"noul","noul":0.9}}}}"#.utf8)
    let transport = FixtureTransport([HTTPResponse(data: Data(), status: 503), HTTPResponse(data: good, status: 200)])
    let client = ClefClient(credentials: testCredentials, transport: transport, retryDelay: 0)
    let scores = try await client.relatedness([evidence("trip-a.txt"), evidence("trip-b.txt")], pairs: [PairKey(0, 1)])
    #expect(scores[PairKey(0, 1)] == 0.9)
    let requests = await transport.requests
    #expect(requests.count == 2)
    #expect(requests[0].httpMethod == "POST")
    #expect(requests[0].url?.path.hasSuffix("/ai/run/@cf/cloudflare/clef") == true)
    let body = try #require(requests[0].httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["model"] as? String == "clef")
    #expect(json["images"] == nil)
    #expect((json["questions"] as? [String: Any])?.count == 1)
}

@Test func credentialsAndAuthenticationFailuresDoNotRetry() async {
    let transport = FixtureTransport([HTTPResponse(data: Data(), status: 403)])
    let client = ClefClient(credentials: testCredentials, transport: transport, retryDelay: 0)
    await #expect(throws: (any Error).self) { try await client.checkCredentials() }
    #expect(await transport.requests.count == 1)
    #expect(throws: (any Error).self) { try CloudflareCredentials(accountID: "invalid", token: "token").validate() }
}

@Test func retriesAreBoundedAndCancellationStopsRequests() async {
    let transport = FixtureTransport([HTTPResponse(data: Data(), status: 429)])
    let client = ClefClient(credentials: testCredentials, transport: transport, retryDelay: 0)
    await #expect(throws: (any Error).self) { try await client.checkCredentials() }
    #expect(await transport.requests.count == 3)
    let task = Task {
        try Task.checkCancellation()
        try await client.checkCredentials()
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func extractionIsBoundedAndLeavesSourceUnchanged() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("travel.txt")
    let original = Data(String(repeating: "travel plans ", count: 5_000).utf8)
    try original.write(to: url)
    let input = try FileIntake.describe(url)
    let result = try await ContentExtractor().extract(input)
    #expect(result.excerpt.count == 1_200)
    #expect(result.preview == nil)
    #expect(try Data(contentsOf: url) == original)
}
