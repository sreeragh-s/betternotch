import Foundation

public enum MoveStatus: String, Codable, Sendable {
    case preparing, moving, completed, failed, undoing, undone, attention
    public var needsAttention: Bool { self != .completed && self != .undone }
}

public enum ItemStage: String, Codable, Sendable {
    case planned, copied, moved, restoring, restoreCopied, restored
}

public struct MoveItem: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var file: FileDescriptor
    public var destination: URL
    public var fingerprint: String
    public var originalStamp: FileStamp
    public var destinationStamp: FileStamp?
    public var restoredStamp: FileStamp?
    public var stage: ItemStage = .planned
    public var error: String?
}

public struct MoveRecord: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var groupID: UUID
    public var name: String
    public var folder: URL
    public var folderStamp: FileStamp?
    public var created = Date()
    public var status: MoveStatus = .preparing
    public var items: [MoveItem] = []
    public var error: String?
    public var movedCount: Int { items.filter { $0.stage == .moved }.count }
}

public struct MoveJournal: Codable, Sendable {
    public var version = 1
    public var records: [MoveRecord] = []
    public init() {}
}
