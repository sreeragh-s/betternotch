import Foundation
import UniformTypeIdentifiers

public struct IntakeResult: Sendable {
    public var files: [FileDescriptor]
    public var warnings: [String]
}

public enum FileIntake {
    public static let limit = 50
    public static func inspect(_ urls: [URL], existing: [FileDescriptor] = []) -> IntakeResult {
        var files = existing
        var seen = Set(existing.map { $0.url.standardizedFileURL.resolvingSymlinksInPath().path })
        var warnings: [String] = []
        for url in urls {
            guard url.isFileURL else { warnings.append("Only local files can be added."); continue }
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            if seen.contains(canonical.path) { continue }
            guard files.count < limit else {
                warnings.append("A session holds up to \(limit) files. Organize these, then start another batch.")
                break
            }
            do {
                let file = try describe(url)
                files.append(file)
                seen.insert(canonical.path)
            } catch { warnings.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        return IntakeResult(files: files, warnings: warnings)
    }

    public static func describe(_ url: URL) throws -> FileDescriptor {
        guard url.isFileURL else { throw SortError.message("Choose a local file.") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
                                                      .fileSizeKey, .contentModificationDateKey, .contentTypeKey,
                                                      .isReadableKey, .ubiquitousItemDownloadingStatusKey])
        guard values.isSymbolicLink != true else { throw SortError.message("Symbolic links are not supported.") }
        guard values.isRegularFile == true, values.isPackage != true else {
            throw SortError.message("Choose individual files rather than folders or app bundles.")
        }
        guard values.isReadable == true else { throw SortError.message("This file cannot be read. Check its permissions.") }
        if let state = values.ubiquitousItemDownloadingStatus, state == .notDownloaded {
            throw SortError.message("Download this file from iCloud in Finder first.")
        }
        return FileDescriptor(url: url.standardizedFileURL, size: Int64(values.fileSize ?? 0),
                              modified: values.contentModificationDate ?? .distantPast,
                              typeIdentifier: values.contentType?.identifier ?? UTType.data.identifier,
                              identity: try LocalFileOperations().stamp(url).identity)
    }

    public static func validateUnchanged(_ file: FileDescriptor) throws {
        let current = try describe(file.url)
        guard current.size == file.size, current.modified == file.modified,
              file.identity == nil || current.identity == file.identity else {
            throw SortError.message("\(file.name) changed since it was added. Add it again before organizing or moving it.")
        }
    }
}
