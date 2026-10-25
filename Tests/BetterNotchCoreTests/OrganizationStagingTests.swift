import Foundation
import Testing
@testable import BetterNotchCore

private func stagedFixture(_ root: URL, operations: any FileOperations = LocalFileOperations()) async throws -> (OrganizationCoordinator, OrganizationSession, [FileDescriptor]) {
    let inputs = [try writeFixture(root, "one/notes.txt", "one"), try writeFixture(root, "two/notes.txt", "two")]
    let coordinator = OrganizationCoordinator(root: root.appendingPathComponent("organization"), fileOperations: operations)
    let session = try await coordinator.stage(inputs)
    return (coordinator, session, inputs)
}

@Test func organizationTakesOwnershipWithoutChangingNamesAndUndoRestoresBothSources() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let (coordinator, session, inputs) = try await stagedFixture(root)
    #expect(session.status == .staged)
    #expect(session.pendingFiles.map(\.name) == ["notes.txt", "notes.txt"])
    #expect(Set(session.pendingFiles.map(\.id)) == Set(inputs.map(\.id)))
    #expect(inputs.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
    #expect(try String(contentsOf: session.pendingFiles[0].url, encoding: .utf8) == "one")
    #expect(try String(contentsOf: session.pendingFiles[1].url, encoding: .utf8) == "two")
    let restarted = OrganizationCoordinator(root: coordinator.root)
    #expect(try await restarted.list().first?.pendingFiles.count == 2)
    #expect(try await restarted.undo(session.id).status == .undone)
    #expect(try String(contentsOf: inputs[0].url, encoding: .utf8) == "one")
    #expect(try String(contentsOf: inputs[1].url, encoding: .utf8) == "two")
}

@Test(arguments: [true, false]) func stagedExportsAlwaysMoveAndUndoReturnsToOriginalParents(crossVolume: Bool) async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let (coordinator, session, inputs) = try await stagedFixture(root, operations: ControlledOperations(forceCopy: crossVolume))
    let group = FileGroup(name: "Notes", files: session.pendingFiles)
    _ = try await coordinator.saveGroups([group], sessionID: session.id)
    let output = try await coordinator.export(group, sessionID: session.id, into: root)
    #expect(output.movedCount == 2); #expect(output.copiedCount == 0)
    #expect(inputs.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
    #expect(session.pendingFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
    #expect(Set(output.items.map { $0.destination.lastPathComponent }) == ["notes.txt", "notes 2.txt"])
    let restarted = OrganizationCoordinator(root: coordinator.root, fileOperations: ControlledOperations(forceCopy: crossVolume))
    #expect(try await restarted.list().first?.status == .completed)
    #expect(try await restarted.undo(session.id).status == .undone)
    #expect(try String(contentsOf: inputs[0].url, encoding: .utf8) == "one")
    #expect(try String(contentsOf: inputs[1].url, encoding: .utf8) == "two")
    #expect(!FileManager.default.fileExists(atPath: output.folder.path))
}

@Test func partiallyExportedSessionsUndoExportedAndStillStagedFilesTogether() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let (coordinator, session, inputs) = try await stagedFixture(root)
    let groups = session.pendingFiles.enumerated().map { FileGroup(name: "Group \($0.offset)", files: [$0.element]) }
    _ = try await coordinator.saveGroups(groups, sessionID: session.id)
    _ = try await coordinator.export(groups[0], sessionID: session.id, into: root)
    let current = try #require(try await coordinator.list().first)
    #expect(current.status == .grouped); #expect(current.pendingFiles.count == 1)
    #expect(current.pendingGroups.map(\.id) == [groups[1].id])
    #expect(try await coordinator.undo(session.id).status == .undone)
    #expect(inputs.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
}

@Test func concurrentFolderPromisesKeepBothIntentsAndUndoProvenance() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let (coordinator, session, inputs) = try await stagedFixture(root)
    let groups = session.pendingFiles.enumerated().map { FileGroup(name: "Group \($0.offset)", files: [$0.element]) }
    _ = try await coordinator.saveGroups(groups, sessionID: session.id)
    async let first = coordinator.export(groups[0], sessionID: session.id, into: root)
    async let second = coordinator.export(groups[1], sessionID: session.id, into: root)
    _ = try await (first, second)
    let current = try #require(try await coordinator.list().first)
    #expect(current.status == .completed); #expect(current.exports.count == 2)
    #expect(current.exports.allSatisfy { $0.completed })
    #expect(try await coordinator.undo(session.id).status == .undone)
    #expect(inputs.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
}

@Test func failedIntakeRollsBackCompletedMovesWithoutHidingRemainingFiles() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let files = [try writeFixture(root, "source/ok.txt"), try writeFixture(root, "source/blocked.txt")]
    let coordinator = OrganizationCoordinator(root: root.appendingPathComponent("organization"), fileOperations: ControlledOperations(failName: "blocked.txt"))
    await #expect(throws: (any Error).self) { try await coordinator.stage(files) }
    #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
    #expect(try await coordinator.list().first?.status == .undone)
}

@Test func cancellationDuringIntakeRestoresCompletedMoves() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let inputs = [try writeFixture(root, "source/a.txt"), try writeFixture(root, "source/b.txt")]
    let coordinator = OrganizationCoordinator(root: root.appendingPathComponent("organization"))
    let task = Task { try await coordinator.stage(inputs) { snapshot in
        if snapshot.files.contains(where: { $0.staged != nil }) { withUnsafeCurrentTask { $0?.cancel() } }
    } }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(inputs.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
    #expect(try await coordinator.list().first?.status == .undone)
}

@Test func occupiedOriginalPathsArePreservedAndUndoCanBeRetried() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let (coordinator, session, inputs) = try await stagedFixture(root)
    try Data("new user file".utf8).write(to: inputs[0].url)
    #expect(try await coordinator.undo(session.id).status == .attention)
    #expect(try String(contentsOf: inputs[0].url, encoding: .utf8) == "new user file")
    #expect(try String(contentsOf: session.pendingFiles[0].url, encoding: .utf8) == "one")
    try FileManager.default.moveItem(at: inputs[0].url, to: root.appendingPathComponent("keep-user-file.txt"))
    #expect(try await coordinator.undo(session.id).status == .undone)
    #expect(try String(contentsOf: inputs[0].url, encoding: .utf8) == "one")
}

@Test func interruptedManifestRetainsJournalProvenanceAcrossCrossVolumeUndo() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let (coordinator, session, inputs) = try await stagedFixture(root, operations: ControlledOperations(forceCopy: true))
    let group = FileGroup(name: "Notes", files: session.pendingFiles)
    _ = try await coordinator.saveGroups([group], sessionID: session.id)
    _ = try await coordinator.export(group, sessionID: session.id, into: root)
    var interrupted = try #require(try await coordinator.list().first)
    interrupted.status = .exporting; interrupted.exports[0].completed = false
    let manifest = coordinator.root.appendingPathComponent("Sessions/\(session.id.uuidString).json")
    try JSONEncoder().encode(interrupted).write(to: manifest, options: .atomic)
    let restarted = OrganizationCoordinator(root: coordinator.root, fileOperations: ControlledOperations(forceCopy: true))
    #expect(try await restarted.list().first?.status == .attention)
    #expect(try await restarted.undo(session.id).status == .undone)
    #expect(inputs.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
}

@Test func interruptedIntakeBeforeDescriptorCheckpointStillRestoresOriginals() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let (coordinator, session, inputs) = try await stagedFixture(root)
    var interrupted = session; interrupted.status = .staging; interrupted.files[0].staged = nil
    try JSONEncoder().encode(interrupted).write(to: coordinator.root.appendingPathComponent("Sessions/\(session.id.uuidString).json"), options: .atomic)
    let restarted = OrganizationCoordinator(root: coordinator.root)
    #expect(try await restarted.list().first?.status == .attention)
    #expect(try await restarted.undo(session.id).status == .undone)
    #expect(inputs.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
}

@Test func changedExportedFilesAreKeptForReviewInsteadOfOverwritingOrDeletingThem() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let (coordinator, session, _) = try await stagedFixture(root)
    let group = FileGroup(name: "Notes", files: session.pendingFiles)
    _ = try await coordinator.saveGroups([group], sessionID: session.id)
    let output = try await coordinator.export(group, sessionID: session.id, into: root)
    try Data("edited output".utf8).write(to: output.items[0].destination)
    #expect(try await coordinator.undo(session.id).status == .attention)
    #expect(try String(contentsOf: output.items[0].destination, encoding: .utf8) == "edited output")
}

@Test func invalidPreviewsAndDuplicateExportsCannotConsumeStagedFilesTwice() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let (coordinator, session, _) = try await stagedFixture(root)
    let group = FileGroup(name: "Notes", files: session.pendingFiles)
    await #expect(throws: (any Error).self) { try await coordinator.saveGroups([FileGroup(name: "Missing", files: [session.pendingFiles[0]])], sessionID: session.id) }
    _ = try await coordinator.saveGroups([group], sessionID: session.id)
    let output = try await coordinator.export(group, sessionID: session.id, into: root)
    await #expect(throws: (any Error).self) { try await coordinator.export(group, sessionID: session.id, into: root) }
    #expect(output.items.allSatisfy { FileManager.default.fileExists(atPath: $0.destination.path) })
}
