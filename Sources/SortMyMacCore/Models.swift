import Foundation

public enum SessionPhase: String, Sendable {
    case idle, receiving, ready, analyzing, grouped, exporting, completed, failed
}

public struct FileDescriptor: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public let size: Int64
    public let modified: Date
    public let typeIdentifier: String

    public init(id: UUID = UUID(), url: URL, size: Int64, modified: Date, typeIdentifier: String) {
        self.id = id
        self.url = url
        self.size = size
        self.modified = modified
        self.typeIdentifier = typeIdentifier
    }

    public var name: String { url.lastPathComponent }
}

public struct FileGroup: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var files: [FileDescriptor]

    public init(id: UUID = UUID(), name: String, files: [FileDescriptor]) {
        self.id = id
        self.name = name
        self.files = files
    }
}

public struct GroupingPlan: Codable, Equatable, Sendable {
    public var groups: [FileGroup]
    public init(groups: [FileGroup]) { self.groups = groups }
}

public enum SortError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}
