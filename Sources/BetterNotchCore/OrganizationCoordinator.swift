import Foundation

public enum OrganizationStatus: String, Codable, Sendable {
    case staging, staged, grouped, exporting, completed, undoing, undone, attention
    public var title: String {
        switch self {
        case .staging: "Moving into Organize"; case .staged: "Held in Organize"; case .grouped: "Ready to move"
        case .exporting: "Moving folders"; case .completed: "Moved"; case .undoing: "Restoring originals"
        case .undone: "Restored"; case .attention: "Needs review"
        }
    }
}

public struct OrganizationFile: Codable, Sendable, Identifiable {
    public var id: UUID { original.id }
    public let original: FileDescriptor
    public let stagingURL: URL
    public let transferID: UUID
    public var staged: FileDescriptor?
}

public struct OrganizationExport: Codable, Sendable, Identifiable {
    public let id: UUID
    public let group: FileGroup
    public let destination: URL
    public var completed = false
}

public struct OrganizationSession: Codable, Sendable, Identifiable {
    public var version = 1
    public let id: UUID
    public var created = Date()
    public var status: OrganizationStatus = .staging
    public var files: [OrganizationFile]
    public var groups: [FileGroup] = []
    public var exports: [OrganizationExport] = []
    public var error: String?
    public var pendingFiles: [FileDescriptor] {
        if status == .undone { return [] }
        let exported = Set(exports.filter(\.completed).flatMap { $0.group.files.map(\.id) })
        return files.filter { !exported.contains($0.id) }.compactMap(\.staged)
    }
    public var pendingGroups: [FileGroup] {
        let pending = Set(pendingFiles.map(\.id))
        return groups.compactMap { group in
            let files = group.files.filter { pending.contains($0.id) }
            return files.isEmpty ? nil : FileGroup(id: group.id, name: group.name, files: files)
        }
    }
    public var canUndo: Bool { status != .undone }
}

public struct StagedOrganizationExporter: FolderExporting {
    public let coordinator: OrganizationCoordinator
    public let sessionID: UUID
    public init(coordinator: OrganizationCoordinator, sessionID: UUID) { self.coordinator = coordinator; self.sessionID = sessionID }
    public func fulfill(_ group: FileGroup, at destination: URL) async throws -> MoveRecord {
        try await coordinator.export(group, sessionID: sessionID, at: destination)
    }
    public func fulfillPromise(_ group: FileGroup, at destination: URL) async throws -> MoveRecord {
        try await coordinator.export(group, sessionID: sessionID, at: destination, receivingPromise: true)
    }
}

/// Durable ownership of temporary originals. Neither cache cleanup nor view dismissal owns these files.
/// Every destructive transfer has a reserved journal ID persisted in the session before it starts.
public actor OrganizationCoordinator {
    public nonisolated let root: URL
    private let transfers: MoveCoordinator
    private let fs: any FileOperations
    private var sessions: [UUID: OrganizationSession] = [:]
    private var loaded = false
    private var exclusiveMutation = false
    private var exporting = Set<UUID>()

    public init(root: URL = UtilityPaths.root.appendingPathComponent("Organization"), fileOperations: any FileOperations = LocalFileOperations()) {
        self.root = root.standardizedFileURL
        fs = fileOperations
        transfers = MoveCoordinator(journalURL: root.appendingPathComponent("transfers.json"), fileOperations: fileOperations)
    }

    public func list() throws -> [OrganizationSession] {
        try load()
        return sessions.values.sorted { $0.created > $1.created }
    }

    public func stage(_ files: [FileDescriptor], progress: @escaping @Sendable (OrganizationSession) async -> Void = { _ in }) async throws -> OrganizationSession {
        try load()
        guard !exclusiveMutation, exporting.isEmpty else { throw SortError.message("Finish the current file transfer first.") }
        guard !sessions.values.contains(where: { $0.status != .completed && $0.status != .undone }) else { throw SortError.message("Finish or Undo the files already held in Organize first.") }
        guard !files.isEmpty, files.count <= FileIntake.limit, Set(files.map(\.id)).count == files.count,
              Set(files.map { $0.url.standardizedFileURL.resolvingSymlinksInPath().path }).count == files.count else {
            throw SortError.message("Choose between 1 and 50 distinct files.")
        }
        for file in files {
            guard !file.url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw SortError.message("These files are already held in Organize.") }
            try FileIntake.validateUnchanged(file)
        }
        exclusiveMutation = true
        defer { exclusiveMutation = false }
        let id = UUID()
        let items = root.appendingPathComponent("Items/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: items, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let entries = files.map { file in
            OrganizationFile(original: file, stagingURL: items.appendingPathComponent(file.id.uuidString, isDirectory: true).appendingPathComponent(file.name), transferID: UUID())
        }
        var session = OrganizationSession(id: id, files: entries)
        try store(session)
        await progress(session)
        do {
            for index in entries.indices {
                try Task.checkCancellation()
                let entry = entries[index]
                _ = try await transfers.fulfill(FileGroup(id: entry.id, name: entry.original.name, files: [entry.original]),
                                                at: entry.stagingURL.deletingLastPathComponent(), policy: .moveOriginals, recordID: entry.transferID)
                let current = try FileIntake.describe(entry.stagingURL)
                session.files[index].staged = FileDescriptor(id: entry.id, url: current.url, size: current.size, modified: current.modified, typeIdentifier: current.typeIdentifier, identity: current.identity)
                try store(session)
                await progress(session)
            }
            try Task.checkCancellation()
            session.status = .staged
            try store(session)
            return session
        } catch {
            let reason = error
            session.status = .attention; session.error = reason.localizedDescription
            try? store(session)
            // Roll back completed moves even when the calling task was canceled.
            if let restored = try? await restore(id) { await progress(restored) }
            throw reason
        }
    }

    public func saveGroups(_ groups: [FileGroup], sessionID: UUID) throws -> OrganizationSession {
        try load()
        guard !exclusiveMutation, exporting.isEmpty, var session = sessions[sessionID], [.staged, .grouped].contains(session.status) else { throw SortError.message("This organization is not ready to edit.") }
        let inputs = groups.flatMap(\.files), expected = session.pendingFiles
        guard Set(inputs.map(\.id)) == Set(expected.map(\.id)), inputs.count == expected.count,
              inputs.allSatisfy({ file in expected.contains(where: { $0.id == file.id && $0.url == file.url }) }) else { throw SortError.message("The folder preview does not match the staged files.") }
        session.groups = groups; session.status = .grouped
        try store(session)
        return session
    }

    public func export(_ group: FileGroup, sessionID: UUID, into parent: URL) async throws -> MoveRecord {
        let name = FolderNames.safeComponent(group.name)
        var destination = parent.appendingPathComponent(name, isDirectory: true), number = 2
        while fs.exists(destination) { destination = parent.appendingPathComponent("\(name) \(number)", isDirectory: true); number += 1 }
        return try await export(group, sessionID: sessionID, at: destination)
    }

    public func export(_ group: FileGroup, sessionID: UUID, at destination: URL, receivingPromise: Bool = false) async throws -> MoveRecord {
        try load()
        guard !exclusiveMutation, var session = sessions[sessionID], [.grouped, .exporting].contains(session.status) else { throw SortError.message("These staged folders are no longer available to move.") }
        let reserved = Set(session.exports.flatMap { $0.group.files.map(\.id) })
        guard !group.files.isEmpty, Set(group.files.map(\.id)).count == group.files.count,
              group.files.allSatisfy({ file in !reserved.contains(file.id) && session.pendingFiles.contains(where: { $0.id == file.id && $0.url == file.url }) }) else { throw SortError.message("These staged files have already moved or changed.") }
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard !target.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw SortError.message("Choose a destination outside temporary Organize storage.") }
        let intent = OrganizationExport(id: UUID(), group: group, destination: destination)
        session.exports.append(intent); session.status = .exporting
        try store(session)
        exporting.insert(intent.id)
        do {
            let record = try await transfers.fulfill(group, at: destination, policy: .moveOriginals, recordID: intent.id, receivingPromise: receivingPromise)
            exporting.remove(intent.id)
            session = sessions[sessionID]!
            if let index = session.exports.firstIndex(where: { $0.id == intent.id }) { session.exports[index].completed = true }
            session.status = session.error != nil ? .attention : session.pendingFiles.isEmpty ? .completed : session.exports.contains(where: { exporting.contains($0.id) }) ? .exporting : .grouped
            try store(session)
            return record
        } catch {
            exporting.remove(intent.id)
            session = sessions[sessionID]!
            session.status = .attention; session.error = error.localizedDescription
            try? store(session)
            throw error
        }
    }

    public func undo(_ sessionID: UUID) async throws -> OrganizationSession {
        try load()
        guard !exclusiveMutation, exporting.isEmpty else { throw SortError.message("Finish the current transfer before Undo.") }
        exclusiveMutation = true
        defer { exclusiveMutation = false }
        return try await restore(sessionID)
    }

    private func restore(_ id: UUID) async throws -> OrganizationSession {
        guard var session = sessions[id] else { throw SortError.message("Organization history was not found.") }
        if session.status == .undone { return session }
        session.status = .undoing; session.error = nil
        try store(session)
        var issues: [String] = []
        var records = try await transfers.records()
        for output in session.exports.reversed() where records.contains(where: { $0.id == output.id }) {
            do {
                let returned = try await transfers.undo(output.id)
                if returned.status != .undone { issues.append(returned.error ?? "An exported folder needs review.") }
            } catch { issues.append(error.localizedDescription) }
        }
        records = try await transfers.records()
        for index in session.files.indices.reversed() {
            let entry = session.files[index]
            do {
                if records.contains(where: { $0.id == entry.transferID }) {
                    for output in session.exports where output.group.files.contains(where: { $0.id == entry.id }) {
                        if records.contains(where: { $0.id == output.id && $0.items.contains(where: { $0.file.id == entry.id && $0.stage == .restored }) }) {
                            try await transfers.adoptReturnedFiles(stagingRecordID: entry.transferID, returnedBy: output.id)
                        }
                    }
                    let restored = try await transfers.undo(entry.transferID)
                    if restored.status != .undone { issues.append(restored.error ?? "An original file needs review.") }
                    else { session.files[index].staged = nil }
                } else {
                    guard !fs.exists(entry.stagingURL) else { throw SortError.message("A staged file has no transfer record. It was preserved for review.") }
                    try FileIntake.validateUnchanged(entry.original)
                }
            } catch { issues.append(error.localizedDescription) }
        }
        session.status = issues.isEmpty ? .undone : .attention
        session.error = issues.isEmpty ? nil : Array(Set(issues)).sorted().joined(separator: "\n")
        try store(session)
        return session
    }

    private func load() throws {
        guard !loaded else { return }
        let folder = root.appendingPathComponent("Sessions")
        if FileManager.default.fileExists(atPath: folder.path) {
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
                var session = try JSONDecoder().decode(OrganizationSession.self, from: Data(contentsOf: url))
                guard session.version == 1, url.deletingPathExtension().lastPathComponent == session.id.uuidString,
                      session.files.allSatisfy({ $0.stagingURL.standardizedFileURL.path.hasPrefix(root.appendingPathComponent("Items/\(session.id.uuidString)").path + "/") }) else { throw SortError.message("Organization history is invalid. It was preserved for review.") }
                if [.staging, .exporting, .undoing].contains(session.status) {
                    session.status = .attention; session.error = "This file transfer was interrupted. Use Undo to restore originals, or inspect the locations in Recovery."
                    try store(session)
                } else { sessions[session.id] = session }
            }
        }
        loaded = true
    }

    private func store(_ session: OrganizationSession) throws {
        let folder = root.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(session.id.uuidString + ".json")
        try JSONEncoder().encode(session).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url); try handle.synchronize(); try handle.close()
        sessions[session.id] = session
    }
}
