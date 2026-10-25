import AppKit
import Foundation
import BetterNotchCore
import Testing
import UniformTypeIdentifiers
@testable import BetterNotch

@MainActor
@Test func nativePromiseDelegateWritesOnlyWhenFulfillmentIsRequested() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BetterNotchPromises-\(UUID())", isDirectory: true)
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
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("BetterNotch.test.\(UUID())"))
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
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BetterNotchRetired-\(UUID())", isDirectory: true)
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

@MainActor @Test(arguments: [true, false]) func organizedPromisesUseTheReceiversFinalParent(backAtSource: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BetterNotch-OrganizedPromise-" + UUID().uuidString)
    let sourceParent = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: sourceParent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = sourceParent.appendingPathComponent("notes.txt")
    try Data("promise fixture".utf8).write(to: source)
    let mover = MoveCoordinator(journalURL: root.appendingPathComponent("history/moves.json"))
    let delegate = FolderPromise(group: FileGroup(name: "Topic", files: [try FileIntake.describe(source)]),
                                 coordinator: OrganizedFolderExporter(coordinator: mover), started: { _ in true }, finished: { _, _ in })
    let provider = NSFilePromiseProvider(fileType: UTType.folder.identifier, delegate: delegate)
    #expect(try await mover.records().isEmpty)
    let destination = (backAtSource ? sourceParent : root).appendingPathComponent("Topic")
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        delegate.filePromiseProvider(provider, writePromiseTo: destination) { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
    }
    let records = try await mover.records()
    #expect(records.first?.items.first?.operation == (backAtSource ? .move : .copy))
    #expect(FileManager.default.fileExists(atPath: source.path) == !backAtSource)
    #expect(try String(contentsOf: destination.appendingPathComponent("notes.txt"), encoding: .utf8) == "promise fixture")
    #expect(try await mover.undo(records[0].id).status == .undone)
    #expect(try String(contentsOf: source, encoding: .utf8) == "promise fixture")
}

@MainActor @Test func stagedFolderPromiseMovesOutAndUndoRestoresTheOriginal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BetterNotch-StagedPromise-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("notes.txt"); try Data("staged original".utf8).write(to: original)
    let coordinator = OrganizationCoordinator(root: root.appendingPathComponent("organization"))
    let session = try await coordinator.stage([FileIntake.describe(original)])
    let group = FileGroup(name: "Notes", files: session.pendingFiles)
    _ = try await coordinator.saveGroups([group], sessionID: session.id)
    let delegate = FolderPromise(group: group, coordinator: StagedOrganizationExporter(coordinator: coordinator, sessionID: session.id), started: { _ in true }, finished: { _, _ in })
    let provider = NSFilePromiseProvider(fileType: UTType.folder.identifier, delegate: delegate)
    let destination = root.appendingPathComponent("Notes")
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        delegate.filePromiseProvider(provider, writePromiseTo: destination) { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
    }
    #expect(!FileManager.default.fileExists(atPath: original.path))
    #expect(!FileManager.default.fileExists(atPath: session.pendingFiles[0].url.path))
    #expect(try String(contentsOf: destination.appendingPathComponent("notes.txt"), encoding: .utf8) == "staged original")
    #expect(try await coordinator.undo(session.id).status == .undone)
    #expect(try String(contentsOf: original, encoding: .utf8) == "staged original")
}

/// Models the read claim held by a receiver while it waits for promised contents.
/// The safety deadline releases the claim even when testing the old deadlocking writer.
private final class PendingPromiseRead: @unchecked Sendable {
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var held = false
    private let queue = OperationQueue()
    var isHeld: Bool { lock.withLock { held } }
    func finish() { release.signal() }
    func acquire(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.addOperation {
                var entered = false
                var error: NSError?
                NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { _ in
                    entered = true
                    self.lock.withLock { self.held = true }
                    continuation.resume()
                    _ = self.release.wait(timeout: .now() + 3)
                    self.lock.withLock { self.held = false }
                }
                if !entered { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
}

@MainActor @Test func promisedMoveCompletesWhileReceiverStillHoldsItsDestinationReadClaim() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BetterNotch-ReceiverClaim-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("notes.txt")
    try Data("receiver waiting for contents".utf8).write(to: original)
    let coordinator = OrganizationCoordinator(root: root.appendingPathComponent("organization"))
    let session = try await coordinator.stage([FileIntake.describe(original)])
    let group = FileGroup(name: "Notes", files: session.pendingFiles)
    _ = try await coordinator.saveGroups([group], sessionID: session.id)
    let delegate = FolderPromise(group: group, coordinator: StagedOrganizationExporter(coordinator: coordinator, sessionID: session.id), started: { _ in true }, finished: { _, _ in })
    let provider = NSFilePromiseProvider(fileType: UTType.folder.identifier, delegate: delegate)
    let destination = root.appendingPathComponent("Notes")
    let receiver = PendingPromiseRead()
    try await receiver.acquire(destination)
    defer { receiver.finish() }
    let completedDuringRead = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
        delegate.filePromiseProvider(provider, writePromiseTo: destination) { error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume(returning: receiver.isHeld) }
        }
    }
    #expect(completedDuringRead, "The provider must not wait for the receiver that is awaiting its completion.")
    #expect(try String(contentsOf: destination.appendingPathComponent("notes.txt"), encoding: .utf8) == "receiver waiting for contents")
    receiver.finish()
    #expect(try await coordinator.undo(session.id).status == .undone)
    #expect(try String(contentsOf: original, encoding: .utf8) == "receiver waiting for contents")
}
