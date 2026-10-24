#if DEBUG
import AppKit
import SortMyMacCore

/// Explicit development-only mode. All fixtures and recovery history live under a fresh temporary directory.
@MainActor
enum SmokeTestSupport {
    static func configure(_ model: AppModel, root: URL) throws {
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        guard canonical.path.hasPrefix("/private/tmp/SortMyMac-QA-") || canonical.path.hasPrefix("/tmp/SortMyMac-QA-") else {
            throw SortError.message("Smoke test directory must be a fresh /tmp/SortMyMac-QA-* directory.")
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
