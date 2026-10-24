import Foundation
import Testing
@testable import SortMyMacCore

struct ControlledOperations: FileOperations {
    let local = LocalFileOperations()
    var forceCopy = false
    var failName: String?
    var corruptCopy = false
    func exists(_ url: URL) -> Bool { local.exists(url) }
    func stamp(_ url: URL) throws -> FileStamp { try local.stamp(url) }
    func digest(_ url: URL) throws -> String { try local.digest(url) }
    func reserveDirectory(_ url: URL) throws -> Bool { try local.reserveDirectory(url) }
    func sameVolume(_ a: URL, _ b: URL) throws -> Bool { forceCopy ? false : try local.sameVolume(a, b) }
    func move(_ a: URL, _ b: URL) throws {
        if a.lastPathComponent == failName { throw SortError.message("Simulated permission failure") }
        try local.move(a, b)
    }
    func copy(_ a: URL, _ b: URL) throws {
        try local.copy(a, b)
        if corruptCopy { try Data("corrupted copy".utf8).write(to: b) }
    }
    func removeFile(_ url: URL, expected: FileStamp, fingerprint: String) throws { try local.removeFile(url, expected: expected, fingerprint: fingerprint) }
    func removeEmptyDirectory(_ url: URL) throws { try local.removeEmptyDirectory(url) }
}

func writeFixture(_ root: URL, _ name: String, _ content: String = "original contents") throws -> FileDescriptor {
    let url = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
    return try FileIntake.describe(url)
}

func testMover(_ root: URL, operations: any FileOperations = LocalFileOperations()) -> MoveCoordinator {
    MoveCoordinator(journalURL: root.appendingPathComponent("history/moves.json"), fileOperations: operations)
}

@Test func movesOriginalsAndUndoSurvivesRestart() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = try writeFixture(root, "sources/Trip-flight.txt", "flight")
    let b = try writeFixture(root, "sources/Trip-hotel.txt", "hotel")
    let mover = testMover(root)
    let record = try await mover.export(FileGroup(name: "Trip", files: [a, b]), into: root)
    #expect(record.status == .completed)
    #expect(!FileManager.default.fileExists(atPath: a.url.path))
    #expect(try String(contentsOf: record.folder.appendingPathComponent(a.name), encoding: .utf8) == "flight")
    let restarted = testMover(root)
    let history = try await restarted.records()
    #expect(history.count == 1)
    let undo = try await restarted.undo(record.id)
    #expect(undo.status == .undone)
    #expect(try String(contentsOf: a.url, encoding: .utf8) == "flight")
    #expect(try String(contentsOf: b.url, encoding: .utf8) == "hotel")
    #expect(!FileManager.default.fileExists(atPath: record.folder.path))
}

@Test func collisionsAreNumberedWithoutOverwritingAnyExistingItem() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sentinel = try writeFixture(root, "Projects/keep.txt", "keep me")
    let a = try writeFixture(root, "one/notes.txt", "one")
    let b = try writeFixture(root, "two/notes.txt", "two")
    let record = try await testMover(root).export(FileGroup(name: "Projects", files: [a, b]), into: root)
    #expect(record.folder.lastPathComponent == "Projects 2")
    #expect(try String(contentsOf: sentinel.url, encoding: .utf8) == "keep me")
    #expect(Set(record.items.map { $0.destination.lastPathComponent }) == ["notes.txt", "notes 2.txt"])
    #expect(try String(contentsOf: record.items[1].destination, encoding: .utf8) == "two")
}

@Test func crossVolumeBranchVerifiesBeforeDeletingSource() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try writeFixture(root, "sources/report.txt")
    let mover = testMover(root, operations: ControlledOperations(forceCopy: true))
    let record = try await mover.export(FileGroup(name: "Reports", files: [file]), into: root)
    #expect(record.status == .completed)
    #expect(!FileManager.default.fileExists(atPath: file.url.path))
    #expect(record.items[0].originalStamp.identity != record.items[0].destinationStamp?.identity)
    let undo = try await mover.undo(record.id)
    #expect(undo.status == .undone)
    #expect(try String(contentsOf: file.url, encoding: .utf8) == "original contents")
}

@Test func failedCopyVerificationAlwaysKeepsTheOriginal() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try writeFixture(root, "sources/report.txt")
    let mover = testMover(root, operations: ControlledOperations(forceCopy: true, corruptCopy: true))
    await #expect(throws: (any Error).self) { try await mover.export(FileGroup(name: "Reports", files: [file]), into: root) }
    #expect(try String(contentsOf: file.url, encoding: .utf8) == "original contents")
    let records = try await mover.records()
    #expect(records[0].status == .failed)
    let undo = try await mover.undo(records[0].id)
    #expect(undo.status == .attention)
    #expect(FileManager.default.fileExists(atPath: file.url.path))
}

@Test func partialFailureHasRecoverableHistory() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let a = try writeFixture(root, "sources/ok.txt")
    let b = try writeFixture(root, "sources/blocked.txt")
    let mover = testMover(root, operations: ControlledOperations(failName: "blocked.txt"))
    await #expect(throws: (any Error).self) { try await mover.export(FileGroup(name: "Work", files: [a, b]), into: root) }
    let records = try await mover.records()
    #expect(records[0].movedCount == 1)
    #expect(records[0].status == .failed)
    #expect(FileManager.default.fileExists(atPath: b.url.path))
    let undo = try await testMover(root).undo(records[0].id)
    #expect(undo.status == .undone)
    #expect(FileManager.default.fileExists(atPath: a.url.path))
}

@Test func undoPreservesOccupiedOriginalAndChangedDestination() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try writeFixture(root, "sources/notes.txt")
    let mover = testMover(root)
    let record = try await mover.export(FileGroup(name: "Notes", files: [file]), into: root)
    try Data("new user file".utf8).write(to: file.url)
    let conflict = try await mover.undo(record.id)
    #expect(conflict.status == .attention)
    #expect(try String(contentsOf: file.url, encoding: .utf8) == "new user file")
    #expect(FileManager.default.fileExists(atPath: record.items[0].destination.path))
    try FileManager.default.moveItem(at: file.url, to: root.appendingPathComponent("new-user-file.txt"))
    try Data("user modified destination".utf8).write(to: record.items[0].destination)
    let changed = try await mover.undo(record.id)
    #expect(changed.status == .attention)
    #expect(try String(contentsOf: record.items[0].destination, encoding: .utf8) == "user modified destination")
}

@Test func sourceReplacementWithSameSizeAndDateIsRejected() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try writeFixture(root, "sources/notes.txt", "aaaa")
    try Data("bbbb".utf8).write(to: file.url, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: file.modified], ofItemAtPath: file.url.path)
    await #expect(throws: (any Error).self) { try await testMover(root).export(FileGroup(name: "Notes", files: [file]), into: root) }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Notes").path))
    #expect(try String(contentsOf: file.url, encoding: .utf8) == "bbbb")
}

@Test func crashAfterRenameBeforeCheckpointCanBeUndone() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try writeFixture(root, "sources/a.txt")
    let mover = testMover(root)
    let record = try await mover.export(FileGroup(name: "Topic", files: [file]), into: root)
    let journalURL = root.appendingPathComponent("history/moves.json")
    var journal = try JSONDecoder().decode(MoveJournal.self, from: Data(contentsOf: journalURL))
    journal.records[0].status = .moving
    journal.records[0].items[0].stage = .planned
    journal.records[0].items[0].destinationStamp = nil
    try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
    let undo = try await testMover(root).undo(record.id)
    #expect(undo.status == .undone)
    #expect(FileManager.default.fileExists(atPath: file.url.path))
}

@Test func corruptJournalIsPreservedAndBlocksFurtherMoves() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let journalURL = root.appendingPathComponent("broken.json")
    let broken = Data("not a journal".utf8)
    try broken.write(to: journalURL)
    let file = try writeFixture(root, "a.txt")
    let mover = MoveCoordinator(journalURL: journalURL)
    await #expect(throws: (any Error).self) { try await mover.export(FileGroup(name: "Group", files: [file]), into: root) }
    #expect(try Data(contentsOf: journalURL) == broken)
    #expect(FileManager.default.fileExists(atPath: file.url.path))
}

@Test func undoNeverRecursivelyDeletesTheFolder() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try writeFixture(root, "sources/a.txt")
    let mover = testMover(root)
    let record = try await mover.export(FileGroup(name: "Group", files: [file]), into: root)
    let added = try writeFixture(record.folder, "user-added.txt", "keep")
    #expect(try await mover.undo(record.id).status == .undone)
    #expect(try String(contentsOf: added.url, encoding: .utf8) == "keep")
}

@Test func verifiedSourceRemovalRefusesChangedFiles() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try writeFixture(root, "source.txt", "before")
    let fs = LocalFileOperations()
    let stamp = try fs.stamp(file.url)
    let hash = try fs.digest(file.url)
    try Data("after change".utf8).write(to: file.url)
    #expect(throws: (any Error).self) { try fs.removeFile(file.url, expected: stamp, fingerprint: hash) }
    #expect(try String(contentsOf: file.url, encoding: .utf8) == "after change")
}

@Test func crashDuringCrossVolumeUndoPreservesVerifiedOriginal() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try writeFixture(root, "sources/a.txt")
    let mover = testMover(root, operations: ControlledOperations(forceCopy: true))
    let record = try await mover.export(FileGroup(name: "Topic", files: [file]), into: root)
    // Simulate the checkpoint after restoring a verified copy, before removing the old destination.
    let fs = LocalFileOperations()
    try fs.copy(record.items[0].destination, file.url)
    let journalURL = root.appendingPathComponent("history/moves.json")
    var journal = try JSONDecoder().decode(MoveJournal.self, from: Data(contentsOf: journalURL))
    journal.records[0].status = .undoing
    journal.records[0].items[0].stage = .restoreCopied
    journal.records[0].items[0].restoredStamp = try fs.stamp(file.url)
    try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
    let undo = try await testMover(root).undo(record.id)
    #expect(undo.status == .undone)
    #expect(try String(contentsOf: file.url, encoding: .utf8) == "original contents")
    #expect(!fs.exists(record.items[0].destination))
}

@Test func replacedDestinationWithIdenticalContentIsKeptForReview() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try writeFixture(root, "sources/a.txt")
    let mover = testMover(root)
    let record = try await mover.export(FileGroup(name: "Topic", files: [file]), into: root)
    let data = try Data(contentsOf: record.items[0].destination)
    try data.write(to: record.items[0].destination, options: .atomic)
    let undo = try await mover.undo(record.id)
    #expect(undo.status == .attention)
    #expect(FileManager.default.fileExists(atPath: record.items[0].destination.path))
}

@Test func duplicateMaximumLengthFilenamesStillFitTheFilesystem() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let name = String(repeating: "a", count: 251) + ".txt"
    let a = try writeFixture(root, "one/" + name)
    let b = try writeFixture(root, "two/" + name)
    let record = try await testMover(root).export(FileGroup(name: "Topic", files: [a, b]), into: root)
    #expect(record.status == .completed)
    #expect(record.items[1].destination.lastPathComponent.utf8.count <= 255)
    #expect(record.items[1].destination.pathExtension == "txt")
}
