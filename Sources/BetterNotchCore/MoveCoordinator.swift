import Foundation

public protocol FolderExporting: Sendable {
    func fulfill(_ group: FileGroup, at destination: URL) async throws -> MoveRecord
    func fulfillPromise(_ group: FileGroup, at destination: URL) async throws -> MoveRecord
}

public extension FolderExporting {
    func fulfillPromise(_ group: FileGroup, at destination: URL) async throws -> MoveRecord { try await fulfill(group, at: destination) }
}

public enum FolderExportPolicy: Sendable {
    case moveOriginals, organizeAtSource
}

/// Finder supplies the final destination only when fulfilling a promise.
public struct OrganizedFolderExporter: FolderExporting {
    public let coordinator: MoveCoordinator
    public init(coordinator: MoveCoordinator) { self.coordinator = coordinator }
    public func fulfill(_ group: FileGroup, at destination: URL) async throws -> MoveRecord {
        try await coordinator.fulfill(group, at: destination, policy: .organizeAtSource)
    }
    public func fulfillPromise(_ group: FileGroup, at destination: URL) async throws -> MoveRecord {
        try await coordinator.fulfill(group, at: destination, policy: .organizeAtSource, receivingPromise: true)
    }
}

/// Serializes writes and persists intent before each destructive step. An ambiguous crash state is
/// left for review, never repaired by guessing which copy the user intended to keep.
public actor MoveCoordinator: FolderExporting {
    public let journalURL: URL
    private let fs: any FileOperations
    private var journal = MoveJournal()
    private var loaded = false

    public init(journalURL: URL, fileOperations: any FileOperations = LocalFileOperations()) {
        self.journalURL = journalURL; self.fs = fileOperations
    }
    public static var defaultJournalURL: URL {
        UtilityPaths.root.appendingPathComponent("moves.json")
    }

    public func records() throws -> [MoveRecord] {
        try load()
        return journal.records.reversed()
    }

    /// Called by a file promise: the supplied URL is Finder's final, collision-resolved filename.
    public func fulfill(_ group: FileGroup, at destination: URL) throws -> MoveRecord {
        try fulfill(group, at: destination, policy: .moveOriginals)
    }

    public func fulfillPromise(_ group: FileGroup, at destination: URL) throws -> MoveRecord {
        try fulfill(group, at: destination, policy: .moveOriginals, receivingPromise: true)
    }

    public func fulfill(_ group: FileGroup, at destination: URL, policy: FolderExportPolicy, recordID: UUID = UUID(), receivingPromise: Bool = false) throws -> MoveRecord {
        try load()
        guard !group.files.isEmpty else { throw SortError.message("This folder has no files to move.") }
        guard Set(group.files.map { $0.url.standardizedFileURL.path }).count == group.files.count else {
            throw SortError.message("The group contains duplicate source files.")
        }
        let requested = destination.standardizedFileURL
        // Resolve the existing parent, since resolving an absent final component can leave
        // directory aliases unresolved. The receiver's final folder name remains unchanged.
        let parent = requested.deletingLastPathComponent().resolvingSymlinksInPath()
        let target = parent.appendingPathComponent(requested.lastPathComponent, isDirectory: true)
        guard target.isFileURL, !fs.exists(target) else {
            throw SortError.message("The destination already exists. Drop again so Finder can choose a new name.")
        }
        guard (try? parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw SortError.message("Drop the folders into an existing Finder folder or onto the Desktop.")
        }
        guard !journal.records.contains(where: { $0.id == recordID }) else { throw SortError.message("This transfer has already been recorded. Review Recovery before retrying.") }
        var record = MoveRecord(id: recordID, groupID: group.id, name: target.lastPathComponent, folder: target)
        var used = Set<String>()
        // Preflight every source before creating any destination or moving any file.
        for file in group.files {
            try FileIntake.validateUnchanged(file)
            let original = try fs.stamp(file.url)
            let fingerprint = try fs.digest(file.url)
            guard try fs.stamp(file.url) == original else { throw SortError.message("\(file.name) changed while preparing the move.") }
            var candidate = file.name
            var counter = 2
            while used.contains(candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))) {
                candidate = try Self.numbered(file.name, number: counter); counter += 1
            }
            used.insert(candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")))
            let sourceParent = file.url.deletingLastPathComponent().resolvingSymlinksInPath()
            let sameParent = try fs.stamp(sourceParent).identity == fs.stamp(parent).identity
            record.items.append(MoveItem(file: file, destination: target.appendingPathComponent(candidate),
                                         fingerprint: fingerprint, originalStamp: original,
                                         operation: policy == .moveOriginals || sameParent ? .move : .copy))
        }
        journal.records.append(record)
        let r = journal.records.count - 1
        try persist()
        do {
            guard try fs.reserveDirectory(target) else { throw SortError.message("The destination appeared during the move. Nothing was overwritten.") }
            journal.records[r].folderStamp = try fs.stamp(target)
            journal.records[r].status = .moving
            try persist()
            for i in journal.records[r].items.indices {
                try transfer(record: r, item: i, receivingPromise: receivingPromise)
            }
            journal.records[r].status = .completed
            try persist()
            return journal.records[r]
        } catch {
            journal.records[r].status = .failed
            journal.records[r].error = error.localizedDescription
            try? persist()
            throw SortError.message("Couldn’t finish \(record.name): \(error.localizedDescription) Open Recovery to inspect or undo this operation.")
        }
    }

    /// Convenience for non-promise destinations and integration tests. Reservation is still exclusive.
    public func export(_ group: FileGroup, into parent: URL, policy: FolderExportPolicy = .moveOriginals) throws -> MoveRecord {
        let name = FolderNames.safeComponent(group.name)
        var destination = parent.appendingPathComponent(name, isDirectory: true)
        var counter = 2
        while fs.exists(destination) {
            destination = parent.appendingPathComponent("\(name) \(counter)", isDirectory: true); counter += 1
        }
        return try fulfill(group, at: destination, policy: policy)
    }

    private func transfer(record r: Int, item i: Int, receivingPromise: Bool) throws {
        let item = journal.records[r].items[i]
        try FileIntake.validateUnchanged(item.file)
        guard try fs.stamp(item.file.url) == item.originalStamp else { throw SortError.message("\(item.file.name) was replaced before it could be moved.") }
        guard !fs.exists(item.destination) else { throw SortError.message("A destination file already exists. Nothing was overwritten.") }
        do {
            if item.operation == .copy {
                if receivingPromise { try fs.copyPromisedFile(item.file.url, item.destination) }
                else { try fs.copy(item.file.url, item.destination) }
                let stamp = try fs.stamp(item.destination)
                journal.records[r].items[i].destinationStamp = stamp
                journal.records[r].items[i].stage = .copied
                try persist()
                guard try fs.digest(item.destination) == item.fingerprint,
                      try fs.stamp(item.file.url) == item.originalStamp,
                      try fs.digest(item.file.url) == item.fingerprint,
                      try fs.stamp(item.destination) == stamp else {
                    throw SortError.message("Copy verification failed for \(item.file.name). The original was kept.")
                }
            } else if try fs.sameVolume(item.file.url, item.destination.deletingLastPathComponent()) {
                if receivingPromise { try fs.movePromisedFile(item.file.url, item.destination) }
                else { try fs.move(item.file.url, item.destination) }
                // Journal the new identity before any subsequent validation can fail.
                journal.records[r].items[i].destinationStamp = try fs.stamp(item.destination)
                journal.records[r].items[i].stage = .moved
                try persist()
                guard try fs.digest(item.destination) == item.fingerprint else {
                    throw SortError.message("\(item.file.name) changed during the move. Its destination copy was preserved for review.")
                }
            } else {
                if receivingPromise { try fs.copyPromisedFile(item.file.url, item.destination) }
                else { try fs.copy(item.file.url, item.destination) }
                let destinationStamp = try fs.stamp(item.destination)
                journal.records[r].items[i].destinationStamp = destinationStamp
                journal.records[r].items[i].stage = .copied
                try persist()
                guard try fs.digest(item.destination) == item.fingerprint,
                      try fs.stamp(item.file.url) == item.originalStamp,
                      try fs.digest(item.file.url) == item.fingerprint,
                      try fs.stamp(item.destination) == destinationStamp else {
                    throw SortError.message("Copy verification failed for \(item.file.name). The source was kept.")
                }
                try fs.removeFile(item.file.url, expected: item.originalStamp, fingerprint: item.fingerprint)
                journal.records[r].items[i].stage = .moved
                try persist()
            }
        } catch {
            journal.records[r].items[i].error = error.localizedDescription
            try? persist()
            throw error
        }
    }

    public func undo(_ recordID: UUID) throws -> MoveRecord {
        try load()
        guard let r = journal.records.firstIndex(where: { $0.id == recordID }) else { throw SortError.message("Move history entry was not found.") }
        if journal.records[r].status == .undone { return journal.records[r] }
        journal.records[r].status = .undoing
        journal.records[r].error = nil
        try persist()
        for i in journal.records[r].items.indices.reversed() {
            do {
                try restore(record: r, item: i)
                journal.records[r].items[i].error = nil
            } catch { journal.records[r].items[i].error = error.localizedDescription }
            try persist()
        }
        let allRestored = journal.records[r].items.allSatisfy { $0.stage == .restored }
        journal.records[r].status = allRestored ? .undone : .attention
        journal.records[r].error = allRestored ? nil : "Some items need review. Resolve the listed conflicts, then retry Undo."
        if allRestored, let stamp = journal.records[r].folderStamp,
           let current = try? fs.stamp(journal.records[r].folder), current.identity == stamp.identity {
            // rmdir refuses nonempty directories; never recursively delete a destination folder.
            try? fs.removeEmptyDirectory(journal.records[r].folder)
        }
        try persist()
        return journal.records[r]
    }

    /// A verified reverse export may restore a staged file with a new identity on another
    /// volume. Adopt it only with provenance from this journal, never from a matching path alone.
    public func adoptReturnedFiles(stagingRecordID: UUID, returnedBy exportRecordID: UUID) throws {
        try load()
        guard let r = journal.records.firstIndex(where: { $0.id == stagingRecordID }),
              let returned = journal.records.first(where: { $0.id == exportRecordID }) else { throw SortError.message("Recovery provenance is missing.") }
        for i in journal.records[r].items.indices {
            let item = journal.records[r].items[i]
            guard let proof = returned.items.first(where: { $0.file.url.standardizedFileURL == item.destination.standardizedFileURL && $0.stage == .restored }),
                  proof.fingerprint == item.fingerprint else { continue }
            let stamp = try fs.stamp(item.destination)
            guard stamp.identity == (proof.restoredStamp?.identity ?? proof.originalStamp.identity),
                  try fs.digest(item.destination) == item.fingerprint else { throw SortError.message("A returned file changed before restoration. It was kept for review.") }
            journal.records[r].items[i].destinationStamp = stamp
        }
        try persist()
    }

    private func restore(record r: Int, item i: Int) throws {
        var item = journal.records[r].items[i]
        if item.stage == .restored { return }
        if item.operation == .copy {
            // Undo a copy only removes our verified output, regardless of later source edits/removal.
            if fs.exists(item.destination) {
                let stamp = try fs.stamp(item.destination)
                guard let expected = item.destinationStamp, stamp.identity == expected.identity,
                      try fs.digest(item.destination) == item.fingerprint else {
                    throw SortError.message("The copied file changed or was replaced. It was kept for review.")
                }
                try fs.removeFile(item.destination, expected: stamp, fingerprint: item.fingerprint)
            }
            journal.records[r].items[i].stage = .restored
            return
        }
        let sourceExists = fs.exists(item.file.url)
        let destinationExists = fs.exists(item.destination)
        if !destinationExists {
            // This also reconciles a crash immediately after a same-volume undo rename.
            if sourceExists, let sourceStamp = try? fs.stamp(item.file.url),
               (sourceStamp.identity == item.originalStamp.identity || sourceStamp.identity == item.restoredStamp?.identity),
               try fs.digest(item.file.url) == item.fingerprint {
                journal.records[r].items[i].stage = .restored; return
            }
            throw SortError.message("Neither a verified destination nor the unchanged original could be found.")
        }
        let stamp = try fs.stamp(item.destination)
        let knownIdentity = item.destinationStamp?.identity ?? item.originalStamp.identity
        guard stamp.identity == knownIdentity, try fs.digest(item.destination) == item.fingerprint else {
            throw SortError.message("The destination was changed or replaced. It was kept for review.")
        }
        if sourceExists {
            let original = try fs.stamp(item.file.url)
            let expected = item.stage == .restoreCopied ? item.restoredStamp?.identity : item.originalStamp.identity
            guard (item.stage == .copied || item.stage == .restoreCopied), original.identity == expected,
                  try fs.digest(item.file.url) == item.fingerprint else {
                throw SortError.message("An item already occupies the original path. Nothing was overwritten.")
            }
            try fs.removeFile(item.destination, expected: stamp, fingerprint: item.fingerprint)
            journal.records[r].items[i].stage = .restored; return
        }
        let parent = item.file.url.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else {
            throw SortError.message("The original parent folder is missing. Restore that folder before retrying Undo.")
        }
        item.stage = .restoring
        journal.records[r].items[i] = item
        try persist()
        if try fs.sameVolume(item.destination, parent) {
            try fs.move(item.destination, item.file.url)
        } else {
            try fs.copy(item.destination, item.file.url)
            journal.records[r].items[i].restoredStamp = try fs.stamp(item.file.url)
            journal.records[r].items[i].stage = .restoreCopied
            try persist()
            guard try fs.digest(item.file.url) == item.fingerprint,
                  try fs.stamp(item.destination) == stamp else {
                throw SortError.message("Restored copy verification failed. Both copies were preserved.")
            }
            try fs.removeFile(item.destination, expected: stamp, fingerprint: item.fingerprint)
        }
        journal.records[r].items[i].stage = .restored
    }

    private func load() throws {
        guard !loaded else { return }
        if FileManager.default.fileExists(atPath: journalURL.path) {
            do {
                journal = try JSONDecoder().decode(MoveJournal.self, from: Data(contentsOf: journalURL))
                guard journal.version == 1 || journal.version == 2 else { throw SortError.message("Unsupported move journal version.") }
            } catch {
                throw SortError.message("Move history could not be read. It was preserved at \(journalURL.path). Resolve the history file before moving more files.")
            }
        }
        loaded = true
    }

    private func persist() throws {
        // Older builds must refuse copy-aware records instead of applying their move-only Undo.
        journal.version = 2
        let parent = journalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: journalURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        let handle = try FileHandle(forWritingTo: journalURL)
        try handle.synchronize(); try handle.close()
    }

    private static func numbered(_ name: String, number: Int) throws -> String {
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        var stem = ext.isEmpty ? name : url.deletingPathExtension().lastPathComponent
        let suffix = ext.isEmpty ? " \(number)" : " \(number).\(ext)"
        guard suffix.utf8.count < 250 else { throw SortError.message("A duplicate filename has an unusually long extension. Shorten its name in Finder before moving it.") }
        while stem.utf8.count + suffix.utf8.count > 255 { stem.removeLast() }
        return stem + suffix
    }
}
