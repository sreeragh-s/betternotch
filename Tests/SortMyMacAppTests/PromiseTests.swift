import AppKit
import Foundation
import SortMyMacCore
import Testing
import UniformTypeIdentifiers
@testable import SortMyMac

@MainActor
@Test func nativePromiseDelegateWritesOnlyWhenFulfillmentIsRequested() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SortMyMacPromises-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt")
    try Data("native file promise".utf8).write(to: source)
    let destination = root.appendingPathComponent("destination", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let coordinator = MoveCoordinator(journalURL: root.appendingPathComponent("journal.json"))
    let group = FileGroup(name: "Topic", files: [try FileIntake.describe(source)])
    let delegate = FolderPromise(group: group, coordinator: coordinator, started: { _ in true }, finished: { _, _ in })
    let provider = NSFilePromiseProvider(fileType: UTType.folder.identifier, delegate: delegate)
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("SortMyMac.test.\(UUID())"))
    defer { pasteboard.releaseGlobally() }
    #expect(pasteboard.writeObjects([provider]))
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(try await coordinator.records().isEmpty)
    let received = destination.appendingPathComponent("Topic")
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        delegate.filePromiseProvider(provider, writePromiseTo: received) { error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
    }
    #expect(received.lastPathComponent == "Topic")
    #expect(try String(contentsOf: received.appendingPathComponent("source.txt"), encoding: .utf8) == "native file promise")
    #expect(!FileManager.default.fileExists(atPath: source.path))
    let records = try await coordinator.records()
    #expect(records.count == 1)
    #expect(try await coordinator.undo(records[0].id).status == .undone)
    #expect(FileManager.default.fileExists(atPath: source.path))
    withExtendedLifetime(delegate) {}
}

@MainActor
@Test func retiredPromiseCannotMoveOriginals() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SortMyMacRetired-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt")
    try Data("keep source".utf8).write(to: source)
    let coordinator = MoveCoordinator(journalURL: root.appendingPathComponent("journal.json"))
    let delegate = FolderPromise(group: FileGroup(name: "Topic", files: [try FileIntake.describe(source)]),
                                 coordinator: coordinator, started: { _ in false }, finished: { _, _ in })
    let provider = NSFilePromiseProvider(fileType: UTType.folder.identifier, delegate: delegate)
    let failed: Bool = await withCheckedContinuation { continuation in
        delegate.filePromiseProvider(provider, writePromiseTo: root.appendingPathComponent("Topic")) { error in
            continuation.resume(returning: error != nil)
        }
    }
    #expect(failed)
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(try await coordinator.records().isEmpty)
}
