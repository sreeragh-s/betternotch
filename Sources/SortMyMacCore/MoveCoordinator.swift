import Foundation

public protocol FolderExporting: Sendable {
    func fulfill(_ group: FileGroup, at destination: URL) async throws -> MoveRecord
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
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SortMyMac", isDirectory: true).appendingPathComponent("moves.json")
    }

    public func records() throws -> [MoveRecord] {
        try load()
        return journal.records.reversed()
    }

    /// Called by a file promise: the supplied URL is Finder's final, collision-resolved filename.
    public func fulfill(_ group: FileGroup, at destination: URL) throws -> MoveRecord {
        try load()
        guard !group.files.isEmpty else { throw SortError.message("This folder has no files to move.") }
        guard Set(group.files.map { $0.url.standardizedFileURL.path }).count == group.files.count else {
            throw SortError.message("The group contains duplicate source files.")
        }
        let target = destination.standardizedFileURL
        guard target.isFileURL, !fs.exists(target) else {
            throw SortError.message("The destination already exists. Drop again so Finder can choose a new name.")
        }
        let parent = target.deletingLastPathComponent()
        guard (try? parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw SortError.message("Drop the folders into an existing Finder folder or onto the Desktop.")
        }
        var record = MoveRecord(groupID: group.id, name: target.lastPathComponent, folder: target)
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
                candidate = Self.numbered(file.name, number: counter); counter += 1
            }
            used.insert(candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")))
            record.items.append(MoveItem(file: file, destination: target.appendingPathComponent(candidate),
                                         fingerprint: fingerprint, originalStamp: original))
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
                try transfer(record: r, item: i)
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
    public func export(_ group: FileGroup, into parent: URL) throws -> MoveRecord {
        let name = FolderNames.safeComponent(group.name)
        var destination = parent.appendingPathComponent(name, isDirectory: true)
        var counter = 2
        while fs.exists(destination) {
            destination = parent.appendingPathComponent("\(name) \(counter)", isDirectory: true); counter += 1
        }
        return try fulfill(group, at: destination)
    }

    private func transfer(record r: Int, item i: Int) throws {
        let item = journal.records[r].items[i]
        try FileIntake.validateUnchanged(item.file)
        guard try fs.stamp(item.file.url) == item.originalStamp else { throw SortError.message("\(item.file.name) was replaced before it could be moved.") }
        guard !fs.exists(item.destination) else { throw SortError.message("A destination file already exists. Nothing was overwritten.") }
        do {
            if try fs.sameVolume(item.file.url, item.destination.deletingLastPathComponent()) {
                try fs.move(item.file.url, item.destination)
                // Journal the new identity before any subsequent validation can fail.
                journal.records[r].items[i].destinationStamp = try fs.stamp(item.destination)
                journal.records[r].items[i].stage = .moved
                try persist()
                guard try fs.digest(item.destination) == item.fingerprint else {
                    throw SortError.message("\(item.file.name) changed during the move. Its destination copy was preserved for review.")
                }
            } else {
                try fs.copy(item.file.url, item.destination)
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
                try fs.removeFile(item.file.url)
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
        if allRestored, let stamp = journal.records[r].folderStamp,
           let current = try? fs.stamp(journal.records[r].folder), current.identity == stamp.identity {
            // rmdir refuses nonempty directories; never recursively delete a destination folder.
            try? fs.removeEmptyDirectory(journal.records[r].folder)
        }
        try persist()
        return journal.records[r]
    }

    private func restore(record r: Int, item i: Int) throws {
        var item = journal.records[r].items[i]
        if item.stage == .restored { return }
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
            try fs.removeFile(item.destination)
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
            try fs.removeFile(item.destination)
        }
        journal.records[r].items[i].stage = .restored
    }

    private func load() throws {
        guard !loaded else { return }
        if FileManager.default.fileExists(atPath: journalURL.path) {
            do {
                journal = try JSONDecoder().decode(MoveJournal.self, from: Data(contentsOf: journalURL))
                guard journal.version == 1 else { throw SortError.message("Unsupported move journal version.") }
            } catch {
                throw SortError.message("Move history could not be read. It was preserved at \(journalURL.path). Resolve the history file before moving more files.")
            }
        }
        loaded = true
    }

    private func persist() throws {
        let parent = journalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: journalURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        let handle = try FileHandle(forWritingTo: journalURL)
        try handle.synchronize(); try handle.close()
    }

    private static func numbered(_ name: String, number: Int) -> String {
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        let stem = ext.isEmpty ? name : url.deletingPathExtension().lastPathComponent
        return ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
    }
}
