import Foundation
import Testing
@testable import BetterNotchCore

@Test func organizingBackIntoTheSourceParentMovesIntoSubfoldersAndUndoes() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = try writeFixture(root, "source/report.txt")
    let mover = testMover(root)
    let record = try await mover.export(FileGroup(name: "Reports", files: [file]), into: file.url.deletingLastPathComponent(), policy: .organizeAtSource)
    #expect(record.items[0].operation == .move)
    #expect(record.movedCount == 1); #expect(record.copiedCount == 0)
    #expect(!FileManager.default.fileExists(atPath: file.url.path))
    #expect(try await testMover(root).undo(record.id).status == .undone)
    #expect(try String(contentsOf: file.url, encoding: .utf8) == "original contents")
}

@Test func organizingElsewhereCopiesAndUndoNeverTouchesAnEditedOriginal() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = try writeFixture(root, "source/report.txt")
    let record = try await testMover(root).export(FileGroup(name: "Reports", files: [file]), into: root, policy: .organizeAtSource)
    #expect(record.items[0].operation == .copy)
    #expect(record.movedCount == 0); #expect(record.copiedCount == 1)
    #expect(try Data(contentsOf: file.url) == Data(contentsOf: record.items[0].destination))
    try Data("edited original".utf8).write(to: file.url)
    #expect(try await testMover(root).undo(record.id).status == .undone)
    #expect(try String(contentsOf: file.url, encoding: .utf8) == "edited original")
    #expect(!FileManager.default.fileExists(atPath: record.folder.path))
}

@Test func copyUndoDoesNotResurrectARemovedSourceAndPreservesUserAddedFiles() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = try writeFixture(root, "source/report.txt")
    let record = try await testMover(root).export(FileGroup(name: "Reports", files: [file]), into: root, policy: .organizeAtSource)
    try FileManager.default.removeItem(at: file.url)
    let added = record.folder.appendingPathComponent("keep.txt"); try Data("keep".utf8).write(to: added)
    #expect(try await testMover(root).undo(record.id).status == .undone)
    #expect(!FileManager.default.fileExists(atPath: file.url.path))
    #expect(try String(contentsOf: added, encoding: .utf8) == "keep")
}

@Test func mixedSourceParentsApplyMoveOrCopyIndependentlyWithoutOverwrites() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let a = try writeFixture(root, "one/report.txt", "one"), b = try writeFixture(root, "two/report.txt", "two")
    let sentinel = try writeFixture(root, "one/Reports/keep.txt", "existing")
    let record = try await testMover(root).export(FileGroup(name: "Reports", files: [a, b]), into: a.url.deletingLastPathComponent(), policy: .organizeAtSource)
    #expect(record.folder.lastPathComponent == "Reports 2")
    #expect(record.movedCount == 1); #expect(record.copiedCount == 1)
    #expect(!FileManager.default.fileExists(atPath: a.url.path))
    #expect(try String(contentsOf: b.url, encoding: .utf8) == "two")
    #expect(Set(record.items.map { $0.destination.lastPathComponent }) == ["report.txt", "report 2.txt"])
    #expect(try String(contentsOf: sentinel.url, encoding: .utf8) == "existing")
    #expect(try await testMover(root).undo(record.id).status == .undone)
    #expect(try String(contentsOf: a.url, encoding: .utf8) == "one")
    #expect(try String(contentsOf: b.url, encoding: .utf8) == "two")
}

@Test func changedOrReplacedExportedCopiesArePreservedDuringUndo() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = try writeFixture(root, "source/report.txt")
    let mover = testMover(root)
    let record = try await mover.export(FileGroup(name: "Reports", files: [file]), into: root, policy: .organizeAtSource)
    let destination = record.items[0].destination
    // Identical contents at a different file identity still belong to the user.
    try Data(contentsOf: destination).write(to: destination, options: .atomic)
    #expect(try await mover.undo(record.id).status == .attention)
    #expect(FileManager.default.fileExists(atPath: destination.path))
    #expect(FileManager.default.fileExists(atPath: file.url.path))
}

@Test func sourceDirectoryAliasesAreMatchedByIdentityAndLegacyJournalsStillUndo() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = try writeFixture(root, "source/report.txt")
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file.url.deletingLastPathComponent())
    let mover = testMover(root)
    let record = try await mover.export(FileGroup(name: "Reports", files: [file]), into: alias, policy: .organizeAtSource)
    #expect(record.items[0].operation == .move)
    let journalURL = root.appendingPathComponent("history/moves.json")
    var journal = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
    journal["version"] = 1
    var records = try #require(journal["records"] as? [[String: Any]])
    var items = try #require(records[0]["items"] as? [[String: Any]])
    items[0].removeValue(forKey: "operation"); records[0]["items"] = items; journal["records"] = records
    try JSONSerialization.data(withJSONObject: journal).write(to: journalURL)
    #expect(try await testMover(root).undo(record.id).status == .undone)
    #expect(FileManager.default.fileExists(atPath: file.url.path))
    let upgraded = try JSONDecoder().decode(MoveJournal.self, from: Data(contentsOf: journalURL))
    #expect(upgraded.version == 2)
}
