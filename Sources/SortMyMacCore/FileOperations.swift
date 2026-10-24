import CryptoKit
import Darwin
import Foundation

public struct FileStamp: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let seconds: Int64
    public let nanoseconds: Int64
    public var identity: String { "\(device):\(inode)" }
}

public protocol FileOperations: Sendable {
    func exists(_ url: URL) -> Bool
    func stamp(_ url: URL) throws -> FileStamp
    func digest(_ url: URL) throws -> String
    func reserveDirectory(_ url: URL) throws -> Bool
    func sameVolume(_ source: URL, _ destinationParent: URL) throws -> Bool
    func move(_ source: URL, _ destination: URL) throws
    func copy(_ source: URL, _ destination: URL) throws
    func removeFile(_ url: URL) throws
    func removeEmptyDirectory(_ url: URL) throws
}

public struct LocalFileOperations: FileOperations {
    public init() {}
    public func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
    public func stamp(_ url: URL) throws -> FileStamp {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posix("Could not inspect \(url.lastPathComponent)") }
        guard (info.st_mode & S_IFMT) != S_IFLNK else { throw SortError.message("A symbolic link replaced \(url.lastPathComponent). No changes were made to it.") }
        return FileStamp(device: UInt64(info.st_dev), inode: UInt64(info.st_ino), size: info.st_size,
                         seconds: Int64(info.st_mtimespec.tv_sec), nanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }
    public func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public func reserveDirectory(_ url: URL) throws -> Bool {
        if mkdir(url.path, 0o755) == 0 { return true }
        if errno == EEXIST { return false }
        throw posix("Could not create destination folder")
    }
    public func sameVolume(_ source: URL, _ destinationParent: URL) throws -> Bool {
        try stamp(source).device == stamp(destinationParent).device
    }
    public func move(_ source: URL, _ destination: URL) throws {
        try coordinate(source, destination, moving: true) { from, to in
            try FileManager.default.moveItem(at: from, to: to)
        }
    }
    public func copy(_ source: URL, _ destination: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var operationError: (any Error)?
        coordinator.coordinate(readingItemAt: source, options: .withoutChanges,
                               writingItemAt: destination, options: [], error: &coordinationError) { from, to in
            do { try FileManager.default.copyItem(at: from, to: to) }
            catch { operationError = error }
        }
        if let error = coordinationError ?? operationError { throw error }
    }
    private func coordinate(_ source: URL, _ destination: URL, moving: Bool, body: (URL, URL) throws -> Void) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var operationError: (any Error)?
        coordinator.coordinate(writingItemAt: source, options: moving ? .forMoving : [],
                               writingItemAt: destination, options: [], error: &coordinationError) { from, to in
            do { try body(from, to) } catch { operationError = error }
        }
        if let error = coordinationError ?? operationError { throw error }
    }
    public func removeFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SortError.message("Refusing to remove an unexpected item at \(url.lastPathComponent).")
        }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var operationError: (any Error)?
        coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { coordinated in
            do { try FileManager.default.removeItem(at: coordinated) } catch { operationError = error }
        }
        if let error = coordinationError ?? operationError { throw error }
    }
    public func removeEmptyDirectory(_ url: URL) throws {
        guard rmdir(url.path) == 0 else {
            if errno == ENOENT { return }
            throw posix("Folder is not empty or cannot be removed")
        }
    }
    private func posix(_ message: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(message): \(String(cString: strerror(errno)))"])
    }
}
