import Foundation
import UniformTypeIdentifiers

public enum NotchRoute: String, Codable, Sendable {
    case home, shelf, fileActions, editor, organize, meetings, recordingSetup, meetingDetail, jobs, results, models, codex, codexDiff
    public var isLarge: Bool { [.editor, .meetingDetail, .codexDiff].contains(self) }
}

public enum FileActionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case organize, resize, convertImage, compressImage, cropImage, removeBackground, extractText
    case trim, convertMedia, compressVideo, extractAudio, makeGIF, transcribe
    case mergePDF, editPDF, compressPDF, makePDF, rename, zip, unzip, duplicates, summarize, shortcut
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .organize: "Organize"; case .resize: "Resize images"; case .convertImage: "Convert images"
        case .compressImage: "Compress images"; case .cropImage: "Crop & rotate"; case .removeBackground: "Remove background"
        case .extractText: "Extract text"; case .trim: "Trim"; case .convertMedia: "Convert media"
        case .compressVideo: "Compress video"; case .extractAudio: "Extract audio"; case .makeGIF: "Make GIF"
        case .transcribe: "Transcribe"; case .mergePDF: "Merge PDFs"; case .editPDF: "Edit PDF pages"
        case .compressPDF: "Compress PDF"; case .makePDF: "Create PDF"; case .rename: "Batch rename"
        case .zip: "Create ZIP"; case .unzip: "Extract ZIP"; case .duplicates: "Find exact duplicates"
        case .summarize: "Summarize locally"; case .shortcut: "Run Shortcut"
        }
    }
    public var symbol: String {
        switch self {
        case .organize: "folder.badge.gearshape"; case .resize: "arrow.up.left.and.arrow.down.right"
        case .convertImage, .convertMedia: "arrow.triangle.2.circlepath"; case .compressImage, .compressVideo, .compressPDF: "arrow.down.right.and.arrow.up.left"
        case .cropImage: "crop.rotate"; case .removeBackground: "person.crop.rectangle"; case .extractText: "text.viewfinder"
        case .trim: "scissors"; case .extractAudio: "waveform"; case .makeGIF: "film.stack"; case .transcribe: "text.bubble"
        case .mergePDF: "doc.on.doc"; case .editPDF: "doc.text"; case .makePDF: "doc.badge.plus"
        case .rename: "pencil.line"; case .zip, .unzip: "archivebox"; case .duplicates: "square.on.square"
        case .summarize: "sparkles"; case .shortcut: "command"
        }
    }
}

public struct FileActionDefinition: Identifiable, Sendable {
    public let kind: FileActionKind
    public let inputs: [FileDescriptor]
    public let totalCount: Int
    public var id: String { kind.rawValue }
    public var label: String { inputs.count == totalCount ? kind.title : "\(kind.title) (\(inputs.count) files)" }
    public static func available(for files: [FileDescriptor]) -> [Self] {
        guard !files.isEmpty else { return [] }
        func conforms(_ f: FileDescriptor, _ type: UTType) -> Bool { UTType(f.typeIdentifier)?.conforms(to: type) == true }
        let images = files.filter { conforms($0, .image) }
        let pdfs = files.filter { conforms($0, .pdf) }
        let media = files.filter { conforms($0, .audiovisualContent) || conforms($0, .audio) }
        let videos = media.filter { conforms($0, .movie) || conforms($0, .video) }
        let documents = files.filter { conforms($0, .text) || $0.url.pathExtension.lowercased() == "rtf" || conforms($0, .image) }
        let textInputs = files.filter { conforms($0, .text) || conforms($0, .pdf) || conforms($0, .image) || $0.url.pathExtension.lowercased() == "rtf" }
        var entries: [(FileActionKind, [FileDescriptor])] = []
        if !media.isEmpty { entries += [(.trim, media), (.transcribe, media), (.convertMedia, media)] }
        if !images.isEmpty { entries += [(.resize, images), (.compressImage, images), (.convertImage, images), (.cropImage, images), (.removeBackground, images)] }
        if pdfs.count > 1 { entries.insert((.mergePDF, pdfs), at: 0) }
        if !pdfs.isEmpty { entries += [(.editPDF, pdfs), (.compressPDF, pdfs)] }
        if !textInputs.isEmpty { entries += [(.extractText, textInputs), (.summarize, textInputs)] }
        if !videos.isEmpty { entries += [(.compressVideo, videos), (.extractAudio, videos), (.makeGIF, videos)] }
        if !documents.isEmpty { entries.append((.makePDF, documents)) }
        entries += [(.organize, files), (.rename, files), (.zip, files)]
        let zips = files.filter { $0.url.pathExtension.lowercased() == "zip" }
        if !zips.isEmpty { entries.append((.unzip, zips)) }
        if files.count > 1 { entries.append((.duplicates, files)) }
        entries.append((.shortcut, files))
        return entries.map { Self(kind: $0.0, inputs: $0.1, totalCount: files.count) }
    }
}

public struct ActionSettings: Codable, Equatable, Sendable {
    public var format = "jpeg"
    public var width = 1600
    public var height = 0
    public var percent = 100.0
    public var resizeMode = "longest"
    public var quality = 0.8
    public var targetBytes: Int64 = 0
    public var rotation = 0
    public var cropX = 0.0, cropY = 0.0, cropWidth = 1.0, cropHeight = 1.0
    public var jpegBackground = "white"
    public var start = 0.0, end = 0.0
    public var mediaPreset = "720p"
    public var pages = ""
    public var splitPages = false
    public var find = "", replacement = "", prefix = "", suffix = ""
    public var numberFiles = false
    public var datePrefix = false
    public var language = "auto"
    public var shortcut = ""
    public init() {}
}
public struct ActionRequest: Codable, Identifiable, Sendable {
    public let id: UUID
    public let kind: FileActionKind
    public let inputs: [FileDescriptor]
    public let settings: ActionSettings
    public init(id: UUID = UUID(), kind: FileActionKind, inputs: [FileDescriptor], settings: ActionSettings) {
        self.id = id; self.kind = kind; self.inputs = inputs; self.settings = settings
    }
}
public struct ActionResult: Codable, Identifiable, Sendable {
    public let id: UUID
    public var outputs: [URL]
    public var messages: [String]
    public var created = Date()
    public init(id: UUID = UUID(), outputs: [URL] = [], messages: [String] = []) { self.id = id; self.outputs = outputs; self.messages = messages }
}
public enum JobStatus: String, Codable, Sendable { case queued, running, canceled, failed, interrupted, completed }
public struct JobRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public var presetSteps: [ActionRequest]?
    public var request: ActionRequest
    public var status: JobStatus = .queued
    public var completed = 0
    public var total = 0
    public var message = "Waiting…"
    public var result: ActionResult?
    public var created = Date()
    public init(request: ActionRequest) { self.id = request.id; self.request = request; self.total = request.inputs.count }
}
public struct ShelfItem: Codable, Identifiable, Sendable {
    public let id: UUID
    public var file: FileDescriptor
    public var bookmark: Data?
    public var managed: Bool
    public var added = Date()
    public init(file: FileDescriptor, managed: Bool = false) {
        self.id = file.id; self.file = file; self.managed = managed
        self.bookmark = try? file.url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    private func matchesIdentity(_ url: URL) -> Bool {
        guard let identity = file.identity else { return true }
        return (try? LocalFileOperations().stamp(url).identity) == identity
    }
    public func resolvedURL() -> URL? {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path), matchesIdentity(url) { return url }
        }
        return FileManager.default.fileExists(atPath: file.url.path) && matchesIdentity(file.url) ? file.url : nil
    }
}
public struct DestinationPin: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var bookmark: Data
    public init(url: URL) throws { name = url.lastPathComponent; bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) }
    public func resolve() throws -> URL { var stale = false; return try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale) }
}
public struct ActionPreset: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var steps: [ActionRequest]
    public init(name: String, steps: [ActionRequest]) { self.name = name; self.steps = steps }
}

public enum UtilityPaths {
    public static var root: URL { AppIdentity.supportRoot(in: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) }
    public static func directory(_ name: String, root: URL = root) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
