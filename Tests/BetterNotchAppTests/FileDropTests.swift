import AppKit
import Foundation
import BetterNotchCore
import Testing
@testable import BetterNotch

private struct DropGroupingFixture: GroupingService {
    func group(_ files: [FileDescriptor], progress: @escaping @Sendable (GroupingProgress) async -> Void) async throws -> GroupingPlan {
        GroupingPlan(groups: [FileGroup(name: "Dropped", files: files)])
    }
}

private struct WaitingDropGroupingFixture: GroupingService {
    func group(_ files: [FileDescriptor], progress: @escaping @Sendable (GroupingProgress) async -> Void) async throws -> GroupingPlan {
        try await Task.sleep(for: .seconds(60))
        return GroupingPlan(groups: [FileGroup(name: "Dropped", files: files)])
    }
}

@MainActor @Test func directUndoCancelsGroupingAndRestoresTheStagedOriginal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BetterNotch-UndoGrouping-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("notes.txt"); try Data("keep original".utf8).write(to: file)
    let model = AppModel(); model.fixtureGroupingService = WaitingDropGroupingFixture()
    await model.hub.start(owner: model, root: root.appendingPathComponent("library"))
    #expect(model.receiveForOrganization([file]))
    for _ in 0..<200 where model.phase == .receiving { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.phase == .analyzing); #expect(model.canUndoOrganization)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    model.undoOrganization()
    for _ in 0..<200 where model.phase == .exporting { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.phase == .idle)
    #expect(try String(contentsOf: file, encoding: .utf8) == "keep original")
    #expect(model.organizationSession?.status == .undone)
    #expect(model.hub.shelf.isEmpty)
}

@MainActor @Test func organizeDropStartsGroupingWithoutAddingOrSelectingShelfFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BetterNotch-Drop-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(); model.fixtureGroupingService = DropGroupingFixture()
    await model.hub.start(owner: model, root: root.appendingPathComponent("library"))
    let parked = root.appendingPathComponent("parked.txt"), dropped = root.appendingPathComponent("dropped.txt")
    try Data("parked".utf8).write(to: parked); try Data("drop".utf8).write(to: dropped)
    model.hub.receive([parked]); let selection = model.hub.selection
    #expect(model.acceptDrop([dropped], to: .organize))
    #expect(model.hub.route == .organize)
    #expect(model.phase == .receiving)
    for _ in 0..<200 where model.phase == .receiving || model.phase == .ready || model.phase == .analyzing { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.phase == .grouped)
    #expect(model.groups.flatMap(\.files).map(\.name) == [dropped.lastPathComponent])
    #expect(model.groups.flatMap(\.files).allSatisfy { $0.url.path.hasPrefix(root.appendingPathComponent("library/Organization").path + "/") })
    #expect(model.hub.shelf.map(\.file.url) == [parked])
    #expect(model.hub.selection == selection)
    #expect(!FileManager.default.fileExists(atPath: dropped.path))
    #expect(model.canUndoOrganization)
    model.undoOrganization()
    for _ in 0..<200 where model.phase == .exporting { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.phase == .idle)
    #expect(FileManager.default.fileExists(atPath: dropped.path))
    await model.hub.persistenceTask?.value
}

@MainActor @Test func shelfDropPreservesAnIndependentOrganizationSession() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BetterNotch-ShelfDrop-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt"), parked = root.appendingPathComponent("parked.txt")
    try Data("source".utf8).write(to: source); try Data("parked".utf8).write(to: parked)
    let model = AppModel(); await model.hub.start(owner: model, root: root.appendingPathComponent("library"))
    model.files = [try FileIntake.describe(source)]
    let group = FileGroup(name: "Original", files: model.files); model.groups = [group]; model.phase = .grouped
    #expect(model.acceptDrop([parked], to: .shelf))
    #expect(model.hub.route == .shelf); #expect(model.phase == .grouped)
    #expect(model.groups == [group]); #expect(model.files.map(\.url) == [source])
    #expect(model.hub.shelf.map(\.file.url) == [parked])
    #expect(!FileActionDefinition.available(for: model.hub.selectedFiles).contains { $0.kind == .organize })
    await model.hub.persistenceTask?.value
}

@MainActor @Test func organizeDropRejectsBusyOrOversizedBatchesWithoutReplacingTheSession() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BetterNotch-LimitDrop-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let urls = try (0..<51).map { index in let url = root.appendingPathComponent("\(index).txt"); try Data("fixture".utf8).write(to: url); return url }
    let model = AppModel(); model.files = [try FileIntake.describe(urls[0])]; model.phase = .grouped
    #expect(!model.acceptDrop(urls, to: .organize))
    #expect(model.files.count == 1); #expect(model.hub.shelf.isEmpty); #expect(model.phase == .grouped)
    #expect(model.hub.error.contains("50"))
    model.phase = .exporting
    #expect(!model.acceptDrop([urls[1]], to: .organize))
    #expect(model.files.map(\.url) == [urls[0]])
}

@MainActor @Test func incomingDropTargetsRequireTheActualCardAndRejectUnavailableOrganization() {
    let model = AppModel()
    model.dropFrames = [.shelf: CGRect(x: 30, y: 100, width: 240, height: 160), .organize: CGRect(x: 290, y: 100, width: 240, height: 160)]
    #expect(model.dropDestination(at: CGPoint(x: 100, y: 150)) == .shelf)
    #expect(model.dropDestination(at: CGPoint(x: 400, y: 150)) == .organize)
    #expect(model.dropDestination(at: CGPoint(x: 280, y: 150)) == nil)
    #expect(model.dropDestination(at: CGPoint(x: 400, y: 50)) == nil)
    model.dragFileCount = 51
    #expect(model.dropDestination(at: CGPoint(x: 400, y: 150)) == nil)
    #expect(model.dropDestination(at: CGPoint(x: 100, y: 150)) == .shelf)
    model.dragFileCount = 2; model.phase = .analyzing
    #expect(model.dropDestination(at: CGPoint(x: 400, y: 150)) == nil)
}
