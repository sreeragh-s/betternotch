import Foundation

public struct RenameItem: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var source: FileDescriptor
    public var destination: URL
    public var temporary: URL
    public var fingerprint: String
    public var stage = "planned"
}
public struct RenameRecord: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var items: [RenameItem]
    public var status = "preparing"
    public var created = Date()
    public var error: String?
}
public actor RenameCoordinator {
    let store: LibraryStore
    public init(store: LibraryStore) { self.store = store }
    public static func preview(_ files: [FileDescriptor], settings: ActionSettings) throws -> [(FileDescriptor, URL)] {
        var used = Set<String>()
        let selected = Set(files.map { $0.url.standardizedFileURL.path.lowercased() })
        return try files.enumerated().map { index, file in
            var stem = file.url.deletingPathExtension().lastPathComponent
            if !settings.find.isEmpty { stem = stem.replacingOccurrences(of: settings.find, with: settings.replacement) }
            stem = settings.prefix + stem + settings.suffix
            if settings.datePrefix { stem = DateFormatter.localizedString(from: file.modified, dateStyle: .short, timeStyle: .none).replacingOccurrences(of: "/", with: "-") + "-" + stem }
            if settings.numberFiles { stem += String(format: "-%03d", index + 1) }
            let name = stem + (file.url.pathExtension.isEmpty ? "" : "." + file.url.pathExtension)
            guard !stem.isEmpty, !name.contains("/"), !name.contains(":"), name != ".", name != "..", name.utf8.count <= 240 else { throw SortError.message("Rename produces an invalid or too-long filename.") }
            let target = file.url.deletingLastPathComponent().appendingPathComponent(name)
            guard used.insert(target.path.lowercased()).inserted else { throw SortError.message("Two files would have the same name. Add numbering or change the pattern.") }
            if LocalFileOperations().exists(target), !selected.contains(target.path.lowercased()) { throw SortError.message("\(name) already exists.") }
            return (file, target)
        }
    }
    public func apply(_ files: [FileDescriptor], settings: ActionSettings) async throws -> RenameRecord {
        let operations = try Self.preview(files, settings: settings)
        let fs = LocalFileOperations()
        let items = try operations.filter { $0.0.url != $0.1 }.map { file, destination -> RenameItem in
            try FileIntake.validateUnchanged(file)
            return RenameItem(source: file, destination: destination, temporary: file.url.deletingLastPathComponent().appendingPathComponent(".betternotch-\(UUID().uuidString)"), fingerprint: try fs.digest(file.url))
        }
        var record = RenameRecord(items: items)
        try await save(record)
        do {
            for index in record.items.indices {
                try Task.checkCancellation(); try FileIntake.validateUnchanged(record.items[index].source)
                try fs.move(record.items[index].source.url, record.items[index].temporary)
                record.items[index].stage = "staged"; try await save(record)
            }
            for index in record.items.indices {
                try Task.checkCancellation()
                try fs.move(record.items[index].temporary, record.items[index].destination)
                record.items[index].stage = "renamed"; try await save(record)
            }
            record.status = "completed"; try await save(record); return record
        } catch {
            record.status = "attention"; record.error = error.localizedDescription; try await save(record); throw error
        }
    }
    public func undo(_ supplied: RenameRecord) async throws -> RenameRecord {
        let fs = LocalFileOperations(); var record = supplied
        // Stage every renamed file first so name swaps and case-only renames can be restored safely.
        for index in record.items.indices {
            let item = record.items[index]
            if item.stage == "restored" { continue }
            if try matches(item.source.url, item), !fs.exists(item.temporary), !fs.exists(item.destination) { record.items[index].stage = "restored"; continue }
            if try matches(item.temporary, item) { record.items[index].stage = "restaging"; continue }
            guard try matches(item.destination, item) else { throw SortError.message("A renamed file changed or is missing. It was preserved for review.") }
            record.items[index].stage = "restaging"; try await save(record)
            try fs.move(item.destination, item.temporary)
            try await save(record)
        }
        for index in record.items.indices where record.items[index].stage != "restored" {
            let item = record.items[index]
            if try matches(item.source.url, item), !fs.exists(item.temporary) { record.items[index].stage = "restored"; try await save(record); continue }
            guard !fs.exists(item.source.url), try matches(item.temporary, item) else { throw SortError.message("Original name is occupied or a staged file changed. Resolve the conflict before retrying Undo.") }
            try fs.move(item.temporary, item.source.url)
            record.items[index].stage = "restored"; try await save(record)
        }
        record.status = "undone"; record.error = nil; try await save(record); return record
    }
    private func matches(_ url: URL, _ item: RenameItem) throws -> Bool {
        let fs = LocalFileOperations()
        guard fs.exists(url) else { return false }
        let stamp = try fs.stamp(url)
        let digest = try fs.digest(url)
        return (item.source.identity == nil || stamp.identity == item.source.identity) && digest == item.fingerprint
    }
    private func save(_ record: RenameRecord) async throws { try await store.save(record, category: "renames", id: record.id.uuidString) }
}
