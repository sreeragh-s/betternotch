import Foundation
import Darwin

/// A private same-user mailbox, without a network listener. Responses are bound to a single expiring request.
public struct CodexBridgeStore: Sendable {
    public static let maximumBytes = 1_048_576
    public let root: URL
    public init(root: URL) { self.root = root }
    public static var standard: Self {
        Self(root: UtilityPaths.root.appendingPathComponent("CodexInbox"))
    }
    public func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try fm.attributesOfItem(atPath: root.path)
        guard values[.type] as? FileAttributeType == .typeDirectory, (values[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw CocoaError(.fileReadNoPermission) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
    public func publish(_ event: CodexEvent) throws { try write(event, to: event.id.uuidString + ".event") }
    public func respond(_ decision: CodexDecision, to event: CodexEvent, now: Date = Date()) throws {
        guard decision.matches(event, now: now), isAvailable(now: now) else { throw CocoaError(.userCancelled) }
        try write(decision, to: event.id.uuidString + ".response")
    }
    public func decision(for event: CodexEvent, now: Date = Date()) -> CodexDecision? {
        guard let data = try? read(root.appendingPathComponent(event.id.uuidString + ".response")),
              let decision = try? JSONDecoder().decode(CodexDecision.self, from: data), decision.matches(event, now: now) else { return nil }
        return decision
    }
    public func heartbeat(now: Date = Date()) throws { try write(now.timeIntervalSince1970, to: "heartbeat") }
    public func isAvailable(now: Date = Date()) -> Bool {
        guard let data = try? read(root.appendingPathComponent("heartbeat")), let time = try? JSONDecoder().decode(Double.self, from: data) else { return false }
        let elapsed = now.timeIntervalSince1970 - time
        return elapsed >= -1 && elapsed < 5
    }
    public func stop() { try? FileManager.default.removeItem(at: root.appendingPathComponent("heartbeat")) }
    public func consume(now: Date = Date()) throws -> [CodexEvent] {
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        // Bound each pass and discard stale messages. No backfill of old conversations.
        var events: [CodexEvent] = []
        for url in urls.filter({ $0.pathExtension == "event" }).prefix(256) {
            defer { try? FileManager.default.removeItem(at: url) }
            guard let data = try? read(url), let event = try? JSONDecoder().decode(CodexEvent.self, from: data),
                  event.createdAt <= now.addingTimeInterval(5), now.timeIntervalSince(event.createdAt) < 3600,
                  url.deletingPathExtension().lastPathComponent == event.id.uuidString else { continue }
            events.append(event)
        }
        // Expired replies cannot be replayed into a later request.
        for url in urls where url.pathExtension == "response" {
            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]), now.timeIntervalSince(values.contentModificationDate ?? .distantPast) > 100 { try? FileManager.default.removeItem(at: url) }
        }
        return events.sorted { $0.createdAt < $1.createdAt }
    }
    public func removeResponse(for event: CodexEvent) { try? FileManager.default.removeItem(at: root.appendingPathComponent(event.id.uuidString + ".response")) }
    private func write<T: Encodable>(_ value: T, to name: String) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= Self.maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let url = root.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func read(_ url: URL) throws -> Data {
        // O_NOFOLLOW closes the symlink race; O_NONBLOCK prevents FIFO input from hanging the app.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_size <= Self.maximumBytes else { throw CocoaError(.fileReadNoPermission) }
        return try file.read(upToCount: Self.maximumBytes + 1) ?? Data()
    }
}
