import Foundation

public struct GroupingProgress: Sendable {
    public let message: String
    public let completed: Int
    public let total: Int
    public let plan: GroupingPlan?
    public init(_ message: String, completed: Int = 0, total: Int = 0, plan: GroupingPlan? = nil) {
        self.message = message; self.completed = completed; self.total = total; self.plan = plan
    }
}

public protocol GroupingService: Sendable {
    func group(_ files: [FileDescriptor], progress: @escaping @Sendable (GroupingProgress) async -> Void) async throws -> GroupingPlan
}

public struct ClefGroupingService: GroupingService {
    private let client: ClefClient
    private let extractor: ContentExtractor
    public init(client: ClefClient, extractor: ContentExtractor = ContentExtractor()) {
        self.client = client; self.extractor = extractor
    }
    public func group(_ files: [FileDescriptor], progress: @escaping @Sendable (GroupingProgress) async -> Void) async throws -> GroupingPlan {
        guard !files.isEmpty, files.count <= FileIntake.limit else { throw SortError.message("Choose between 1 and 50 files.") }
        let sorted = files.sorted { $0.url.path < $1.url.path }
        var evidence: [FileEvidence] = []
        for (index, file) in sorted.enumerated() {
            try Task.checkCancellation()
            await progress(GroupingProgress("Reading \(index + 1) of \(sorted.count) files…", completed: index, total: sorted.count))
            evidence.append(try await extractor.extract(file))
        }
        let batches = Self.batches(evidence)
        var scores: [PairKey: Double] = [:]
        let localPlan = TopicClusterer.plan(evidence, scores: scores, includeUncertain: false)
        if !localPlan.groups.isEmpty {
            let message = batches.isEmpty ? "Screenshots gathered locally." : "Screenshots gathered · finding topics in remaining files…"
            await progress(GroupingProgress(message, plan: localPlan))
        }
        if !batches.isEmpty { try client.credentials.validate() }
        for (index, batch) in batches.enumerated() {
            try Task.checkCancellation()
            await progress(GroupingProgress("Finding connections · batch \(index + 1) of \(batches.count)", completed: index, total: batches.count))
            let decisions = try await client.relatedness(evidence, pairs: batch)
            scores.merge(decisions) { _, new in new }
            // New members only join if every pair is already verified. Unknown edges never imply a relationship.
            let preview = TopicClusterer.plan(evidence, scores: scores, includeUncertain: false)
            await progress(GroupingProgress("Compared \(scores.count) connections", completed: index + 1, total: batches.count, plan: preview))
        }
        try Task.checkCancellation()
        for file in sorted { try FileIntake.validateUnchanged(file) }
        return TopicClusterer.plan(evidence, scores: scores)
    }

    static func batches(_ evidence: [FileEvidence]) -> [[PairKey]] {
        var batches: [[PairKey]] = []
        var current: [PairKey] = []
        let topicIndexes = evidence.indices.filter { !evidence[$0].isScreenshot }
        for a in topicIndexes {
            for b in topicIndexes where b > a {
                if current.count == 64 {
                    batches.append(current); current = []
                }
                current.append(PairKey(a, b))
            }
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }
}

public enum TopicClusterer {
    public static func plan(_ evidence: [FileEvidence], scores: [PairKey: Double], includeUncertain: Bool = true) -> GroupingPlan {
        // Complete-link clustering: all cross-group relationships must exceed the threshold.
        var clusters = evidence.indices.filter { !evidence[$0].isScreenshot }.map { [$0] }
        while true {
            var best: (Int, Int, Double)?
            for a in clusters.indices {
                for b in clusters.indices where b > a {
                    let links = clusters[a].flatMap { x in clusters[b].map { scores[PairKey(x, $0)] ?? 0 } }
                    let minimum = links.min() ?? 0
                    if minimum >= 0.8, minimum > (best?.2 ?? 0) { best = (a, b, minimum) }
                }
            }
            guard let (a, b, _) = best else { break }
            clusters[a] = (clusters[a] + clusters[b]).sorted()
            clusters.remove(at: b)
        }
        var groups: [FileGroup] = []
        var uncertain: [FileDescriptor] = []
        var names: [String: Int] = [:]
        let screenshots = evidence.filter(\.isScreenshot).map(\.file)
        if let first = screenshots.first {
            groups.append(FileGroup(id: first.id, name: "Screenshots", files: screenshots))
            names["Screenshots"] = 1
        }
        for cluster in clusters {
            let items = cluster.map { evidence[$0] }
            if cluster.count == 1 { uncertain.append(items[0].file); continue }
            let base = TopicNamer.name(items)
            names[base, default: 0] += 1
            let name = names[base]! > 1 ? "\(base) \(names[base]!)" : base
            // A stable seed makes incremental classification animation preserve folder identity.
            groups.append(FileGroup(id: items[0].file.id, name: name, files: items.map(\.file)))
        }
        if includeUncertain, !uncertain.isEmpty {
            groups.append(FileGroup(id: uncertain[0].id, name: "Other", files: uncertain))
        }
        return GroupingPlan(groups: groups)
    }
}

public enum TopicNamer {
    private static let stop: Set<String> = ["the", "and", "for", "with", "from", "this", "that", "file", "files", "document", "documents", "image", "copy", "final", "draft", "notes", "untitled", "pdf", "txt", "jpg", "png", "jpeg", "docx", "rtf", "are", "was", "have", "has", "our", "your", "you", "not", "all", "will", "can", "its", "into", "http", "https", "www", "com"]
    public static func name(_ items: [FileEvidence]) -> String {
        var counts: [String: Int] = [:]
        var documentCounts: [String: Int] = [:]
        for item in items {
            let base = item.file.url.deletingPathExtension().lastPathComponent
            let filenameTerms = terms(base)
            let contentTerms = terms(String(item.excerpt.prefix(400)))
            for term in Set(filenameTerms + contentTerms) {
                counts[term, default: 0] += 1
                documentCounts[term, default: 0] += 1
            }
            for term in Set(filenameTerms) { counts[term, default: 0] += 1 }
        }
        let best = counts.filter { documentCounts[$0.key, default: 0] >= 2 }.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.prefix(2).map { $0.key.capitalized }
        return best.isEmpty ? "Related Files" : best.joined(separator: " ")
    }
    private static func terms(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !$0.allSatisfy(\.isNumber) && !stop.contains($0) }.map { String($0.prefix(30)) }
    }
}
