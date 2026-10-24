import Foundation
import Testing
@testable import SortMyMacCore

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("SortMyMacTests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func intakeRejectsDirectoriesLinksAndDeduplicatesFiles() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("notes.txt")
    try Data("hello".utf8).write(to: file)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    let result = FileIntake.inspect([root, link, file, file])
    #expect(result.files.count == 1)
    #expect(result.warnings.count == 2)
    #expect(try Data(contentsOf: file) == Data("hello".utf8))
}

@Test func intakeCapsAtFiftyAndReportsMissingFiles() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let urls = try (0..<51).map { index in
        let url = root.appendingPathComponent("file\(index).txt")
        try Data().write(to: url)
        return url
    }
    let result = FileIntake.inspect(urls)
    #expect(result.files.count == 50)
    #expect(result.warnings.count == 1)
    #expect(FileIntake.inspect([root.appendingPathComponent("missing")]).warnings.count == 1)
}

@Test func detectsChangedSource() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("change.txt")
    try Data("one".utf8).write(to: url)
    let file = try FileIntake.describe(url)
    try Data("updated document".utf8).write(to: url)
    #expect(throws: (any Error).self) { try FileIntake.validateUnchanged(file) }
}
