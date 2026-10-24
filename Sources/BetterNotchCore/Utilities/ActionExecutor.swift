import Foundation
import ZIPFoundation

public actor ActionExecutor {
    private let root: URL
    public init(root: URL = UtilityPaths.root) { self.root = root }
    public func execute(_ request: ActionRequest, progress: @escaping @Sendable (Int, Int, String) async -> Void) async throws -> ActionResult {
        let staging = try UtilityPaths.directory("Staging/\(request.id.uuidString)", root: root)
        let published = root.appendingPathComponent("Outputs/\(request.id.uuidString)")
        var result = ActionResult(id: request.id)
        do {
            for file in request.inputs { try FileIntake.validateUnchanged(file) }
            switch request.kind {
            case .mergePDF, .makePDF:
                let url = staging.appendingPathComponent(request.kind == .mergePDF ? "Merged.pdf" : "Document.pdf")
                try PDFProcessor.render(request.inputs, kind: request.kind, settings: request.settings, to: url); result.outputs = [url]
            case .zip:
                let url = staging.appendingPathComponent("Archive.zip")
                let archive = try Archive(url: url, accessMode: .create)
                var names = Set<String>()
                for (i, file) in request.inputs.enumerated() {
                    try Task.checkCancellation()
                    let name = Self.uniqueName(file.name, used: &names)
                    try archive.addEntry(with: name, fileURL: file.url, compressionMethod: .deflate)
                    await progress(i + 1, request.inputs.count, "Adding \(file.name)")
                }
                result.outputs = [url]
            case .duplicates:
                var groups: [String: [FileDescriptor]] = [:]
                let candidates = Dictionary(grouping: request.inputs, by: \.size).values.filter { $0.count > 1 }.flatMap { $0 }
                for (i, file) in candidates.enumerated() {
                    try Task.checkCancellation()
                    groups[try LocalFileOperations().digest(file.url), default: []].append(file)
                    await progress(i + 1, candidates.count, "Comparing \(file.name)")
                }
                let duplicates = groups.values.filter { $0.count > 1 }.sorted { $0[0].name < $1[0].name }
                result.messages = duplicates.isEmpty ? ["No exact duplicates found."] : duplicates.enumerated().map { "Set \($0.offset + 1): " + $0.element.map { $0.url.path }.joined(separator: "\n") }
            default:
                var used = Set<String>()
                for (i, file) in request.inputs.enumerated() {
                    try Task.checkCancellation()
                    await progress(i, request.inputs.count, "Processing \(file.name)")
                    do {
                        let extensionName = Self.outputExtension(request)
                        let base = file.url.deletingPathExtension().lastPathComponent
                        let name = Self.uniqueName("\(base)-\(request.kind.rawValue).\(extensionName)", used: &used)
                        let output = staging.appendingPathComponent(name)
                        switch request.kind {
                        case .resize, .convertImage, .compressImage, .cropImage, .removeBackground:
                            try ImageProcessor.render(file, kind: request.kind, settings: request.settings, to: output)
                        case .extractText:
                            try Data(PDFProcessor.extractedText(file).utf8).write(to: output, options: .withoutOverwriting)
                        case .editPDF, .compressPDF:
                            if request.kind == .editPDF, request.settings.splitPages {
                                let document = try PDFProcessor.document(file.url)
                                let pages = try PDFProcessor.pageIndices(request.settings.pages, count: document.pageCount)
                                for (pageIndex, page) in pages.enumerated() {
                                    try Task.checkCancellation()
                                    var pageSettings = request.settings; pageSettings.pages = String(page + 1)
                                    let pageURL = staging.appendingPathComponent(Self.uniqueName("\(base)-page-\(pageIndex + 1).pdf", used: &used))
                                    try PDFProcessor.render([file], kind: .editPDF, settings: pageSettings, to: pageURL)
                                    result.outputs.append(pageURL)
                                }
                                continue
                            }
                            try PDFProcessor.render([file], kind: request.kind, settings: request.settings, to: output)
                            if request.kind == .compressPDF, let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize, size >= file.size { result.messages.append("\(file.name): output is not smaller than the original.") }
                        case .trim, .convertMedia, .compressVideo, .extractAudio, .makeGIF:
                            try await MediaProcessor.render(file.url, kind: request.kind, settings: request.settings, to: output)
                        case .unzip:
                            let folder = staging.appendingPathComponent(Self.uniqueName(base, used: &used), isDirectory: true)
                            try Self.extractZIP(file.url, to: folder)
                            result.outputs.append(folder)
                            await progress(i + 1, request.inputs.count, "Extracted \(file.name)")
                            continue
                        case .shortcut:
                            guard !request.settings.shortcut.trimmingCharacters(in: .whitespaces).isEmpty else { throw SortError.message("Choose a configured Shortcut.") }
                            try await NativeProcess.run(executable: URL(fileURLWithPath: "/usr/bin/shortcuts"), arguments: ["run", request.settings.shortcut, "--input-path", file.url.path, "--output-path", output.path])
                        default: throw SortError.message("This action requires its dedicated editor.")
                        }
                        try FileIntake.validateUnchanged(file)
                        guard FileManager.default.fileExists(atPath: output.path) else { throw SortError.message("No output was generated.") }
                        result.outputs.append(output)
                    } catch is CancellationError { throw CancellationError() }
                    catch { result.messages.append("\(file.name): \(error.localizedDescription)") }
                    await progress(i + 1, request.inputs.count, "Processed \(file.name)")
                }
            }
            try Task.checkCancellation()
            for file in request.inputs { try FileIntake.validateUnchanged(file) }
            if !result.outputs.isEmpty {
                try FileManager.default.createDirectory(at: published.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: staging, to: published)
                result.outputs = result.outputs.map { published.appendingPathComponent($0.lastPathComponent) }
            } else {
                try? FileManager.default.removeItem(at: staging)
                if request.kind != .duplicates { throw SortError.message(result.messages.joined(separator: "\n")) }
            }
            return result
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }
    public static func outputExtension(_ request: ActionRequest) -> String {
        switch request.kind {
        case .extractText, .summarize: "txt"
        case .mergePDF, .editPDF, .compressPDF, .makePDF: "pdf"
        case .makeGIF: "gif"
        case .extractAudio: ["wav", "aiff"].contains(request.settings.format) ? request.settings.format : "m4a"
        case .trim, .convertMedia, .compressVideo: ["mp4", "mov", "m4a", "wav", "aiff"].contains(request.settings.format) ? request.settings.format : "mp4"
        case .shortcut: "output"
        default: request.settings.format == "jpeg" ? "jpg" : request.settings.format
        }
    }
    public static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        let safe = String(name.replacingOccurrences(of: "/", with: "-").prefix(160))
        let url = URL(fileURLWithPath: safe), ext = url.pathExtension, stem = url.deletingPathExtension().lastPathComponent
        var candidate = safe, index = 2
        while !used.insert(candidate.lowercased()).inserted { candidate = "\(stem) \(index)" + (ext.isEmpty ? "" : ".\(ext)"); index += 1 }
        return candidate
    }
    public static func extractZIP(_ url: URL, to folder: URL, maximumBytes: Int64 = 5_000_000_000) throws {
        let archive = try Archive(url: url, accessMode: .read)
        var bytes: Int64 = 0, entries = 0
        var paths = Set<String>()
        for entry in archive {
            entries += 1
            guard let size = Int64(exactly: entry.uncompressedSize), size <= maximumBytes - bytes else { throw SortError.message("ZIP exceeds extraction limits.") }
            bytes += size
            let path = entry.path
            guard entries <= 10_000, bytes <= maximumBytes, !path.hasPrefix("/"), !path.contains("\\"),
                  !path.split(separator: "/").contains(".."), entry.type != .symlink,
                  paths.insert(path.lowercased()).inserted else { throw SortError.message("ZIP contains unsafe paths, conflicting names, links, or exceeds extraction limits.") }
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            var extracted: Int64 = 0
            for entry in archive {
                try Task.checkCancellation()
                let target = folder.appendingPathComponent(entry.path)
                if entry.type == .directory { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true); continue }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw SortError.message("Cannot create extracted file.") }
                let handle = try FileHandle(forWritingTo: target)
                defer { try? handle.close() }
                let checksum = try archive.extract(entry) { data in
                    try Task.checkCancellation(); extracted += Int64(data.count)
                    guard extracted <= maximumBytes else { throw SortError.message("ZIP exceeds extraction limit.") }
                    try handle.write(contentsOf: data)
                }
                guard checksum == entry.checksum else { throw SortError.message("ZIP checksum verification failed.") }
            }
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
}

/// Terminate child work on cancellation. Arguments are passed directly, never through a shell.
public enum NativeProcess {
    public static func run(executable: URL, arguments: [String]) async throws {
        let box = ProcessBox()
        try await withTaskCancellationHandler {
            try await Task.detached {
                try Task.checkCancellation()
                let process = Process(); process.executableURL = executable; process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try box.start(process)
                process.waitUntilExit(); try Task.checkCancellation(); if box.wasCanceled { throw CancellationError() }
                guard process.terminationStatus == 0 else { throw SortError.message("\(executable.lastPathComponent) failed (\(process.terminationStatus)).") }
            }.value
        } onCancel: { box.cancel() }
    }
}
private final class ProcessBox: @unchecked Sendable {
    let lock = NSLock(); var process: Process?; var canceled = false
    var wasCanceled: Bool { lock.lock(); defer { lock.unlock() }; return canceled }
    func start(_ value: Process) throws { lock.lock(); defer { lock.unlock() }; guard !canceled else { throw CancellationError() }; process = value; try value.run() }
    func cancel() { lock.lock(); defer { lock.unlock() }; canceled = true; if process?.isRunning == true { process?.terminate() } }
}

public struct ArchiveEntryInfo: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let bytes: Int64
    public let directory: Bool
}
extension ActionExecutor {
    public static func archiveContents(_ url: URL) throws -> [ArchiveEntryInfo] {
        let archive = try Archive(url: url, accessMode: .read)
        var entries: [ArchiveEntryInfo] = []
        for entry in archive {
            guard entries.count < 10_000 else { throw SortError.message("Archive contains more than 10,000 entries.") }
            guard let bytes = Int64(exactly: entry.uncompressedSize) else { throw SortError.message("Archive entry size is invalid.") }
            entries.append(ArchiveEntryInfo(path: entry.path, bytes: bytes, directory: entry.type == .directory))
        }
        return entries
    }
}

extension ActionExecutor {
    public func executePipeline(id: UUID, steps: [ActionRequest], inputs: [FileDescriptor], progress: @escaping @Sendable (Int, Int, String) async -> Void) async throws -> ActionResult {
        guard !steps.isEmpty, steps.count <= 12 else { throw SortError.message("A preset needs between 1 and 12 steps.") }
        let unsupported: Set<FileActionKind> = [.organize, .rename, .transcribe, .summarize, .duplicates]
        var current = inputs, intermediate: [URL] = [], final: ActionResult?
        do {
            for (index, step) in steps.enumerated() {
                try Task.checkCancellation()
                guard !unsupported.contains(step.kind), let definition = FileActionDefinition.available(for: current).first(where: { $0.kind == step.kind }), definition.inputs.count == current.count else { throw SortError.message("Step \(index + 1) (\(step.kind.title)) cannot process every output from the previous step.") }
                let request = ActionRequest(kind: step.kind, inputs: current, settings: step.settings)
                await progress(index, steps.count, "Step \(index + 1): \(step.kind.title)")
                let result = try await execute(request) { _, _, _ in }
                guard result.messages.isEmpty else { throw SortError.message(result.messages.joined(separator: "\n")) }
                intermediate.append(root.appendingPathComponent("Outputs/\(result.id.uuidString)"))
                final = result
                if index + 1 < steps.count { current = try result.outputs.map(FileIntake.describe) }
                await progress(index + 1, steps.count, "Completed step \(index + 1)")
            }
            guard let final else { throw SortError.message("Preset created no output.") }
            let target = root.appendingPathComponent("Outputs/\(id.uuidString)")
            guard let source = intermediate.popLast() else { throw SortError.message("Preset output is missing.") }
            try FileManager.default.moveItem(at: source, to: target)
            for directory in intermediate { try? FileManager.default.removeItem(at: directory) }
            return ActionResult(id: id, outputs: final.outputs.map { target.appendingPathComponent($0.lastPathComponent) }, messages: final.messages)
        } catch { for directory in intermediate { try? FileManager.default.removeItem(at: directory) }; throw error }
    }
}
