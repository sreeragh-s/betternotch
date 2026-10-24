import AppKit
import ImageIO
import UniformTypeIdentifiers
import PDFKit
import BetterNotchCore
import SwiftUI

struct ActionEditor: View {
    @ObservedObject var hub: HubModel
    @State private var previewIndex = 0
    @State private var presetName = ""
    private var kind: FileActionKind { hub.editorKind ?? .resize }
    private var imageAction: Bool { [.resize, .convertImage, .compressImage, .cropImage, .removeBackground].contains(kind) }
    private var mediaAction: Bool { [.trim, .convertMedia, .compressVideo, .extractAudio, .makeGIF].contains(kind) }
    private var pdfAction: Bool { [.mergePDF, .editPDF, .compressPDF, .makePDF].contains(kind) }
    var body: some View {
        Group {
        if imageAction { ImageEditor(hub: hub) }
        else { VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(kind.title, systemImage: kind.symbol).font(.title2.weight(.semibold))
                Spacer()
                Text("\(hub.editorInputs.count) file\(hub.editorInputs.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                if hub.editorInputs.count > 1 {
                    Picker("Preview file", selection: $previewIndex) { ForEach(Array(hub.editorInputs.enumerated()), id: \.offset) { index, file in Text(file.name).tag(index) } }.frame(maxWidth: 230)
                }
            }
            if let preset = hub.pendingPreset { Text(preset.name + " · " + preset.steps.map { $0.kind.title }.joined(separator: " → ")).font(.caption).foregroundStyle(Color.accentColor) }
            if kind == .rename { RenameEditor(hub: hub) }
            else if kind == .transcribe { transcriptionOptions }
            else {
                HStack(alignment: .top, spacing: 16) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if pdfAction { PDFOptions(hub: hub, kind: kind) }
                            else if mediaAction { mediaOptions }
                            else if kind == .shortcut { TextField("Shortcut name", text: $hub.settings.shortcut); Text("Runs your chosen macOS Shortcut with each file. Its output appears here when complete.").font(.caption).foregroundStyle(.secondary) }
                            else if kind == .summarize { Text("Uses your local Ollama server. Configure it in Settings → Local AI.").font(.callout); TextField("Ollama model", text: $hub.ollamaModel) }
                            else if kind == .duplicates { Text("Compares file sizes and SHA-256 hashes. Results list exact matches for your review.").font(.callout) }
                            else if kind == .unzip { Text("Preview ZIP contents below. Extraction creates a new folder; unsafe paths and links are rejected.").font(.callout); ArchiveContentsView(url: inputURL) }
                            else { Text("Create a new output, preview it, then keep or save it.").font(.callout) }
                            DisclosureGroup("Presets") {
                                TextField("Preset name", text: $presetName)
                                Button("Save settings as preset") { hub.savePreset(name: presetName) }
                                if !hub.presets.isEmpty { Menu("Append step") { ForEach(hub.presets) { preset in Button(preset.name) { hub.appendPresetStep(preset) } } } }
                            }.font(.caption)

                        }.hubPanel()
                    }.frame(width: 260)
                    VStack(spacing: 8) {
                        if mediaAction { MediaEditor(url: inputURL, settings: $hub.settings, kind: kind) }
                        else { FilePreview(url: previewURL).frame(maxWidth: .infinity, maxHeight: .infinity) }
                        if let result = hub.previewResult { resultDetails(result) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(maxHeight: .infinity)
            }
            bottomBar.hubActionBar()
        }
        } }
        .onChange(of: hub.settings) { _, _ in hub.settingsChanged() }
        .onChange(of: hub.editorInputs.map(\.id)) { _, _ in previewIndex = 0; hub.settingsChanged() }
        .onDisappear { /* The HubModel keeps settings and accepted results across navigation. */ }
    }
    private var inputURL: URL { hub.editorInputs[min(previewIndex, max(0, hub.editorInputs.count - 1))].url }
    private var previewURL: URL { hub.previewResult?.outputs.first ?? inputURL }
    private var mediaOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if kind != .makeGIF {
                HubFormField("Output format") { Picker("Output", selection: $hub.settings.format) {
                    ForEach(kind == .extractAudio || UTType(hub.editorInputs[min(previewIndex, hub.editorInputs.count - 1)].typeIdentifier)?.conforms(to: .audio) == true ? ["m4a", "wav", "aiff"] : ["mp4", "mov", "m4a", "wav", "aiff"], id: \.self) { Text($0.uppercased()).tag($0) }
                }.labelsHidden() }
                if UTType(hub.editorInputs[min(previewIndex, hub.editorInputs.count - 1)].typeIdentifier)?.conforms(to: .audio) != true {
                    HubFormField("Video quality") { Picker("Video quality", selection: $hub.settings.mediaPreset) { Text("720p").tag("720p"); Text("1080p").tag("1080p"); Text("Source dimensions").tag("original") }.labelsHidden() }
                }
            }
            Text(kind == .makeGIF ? "GIFs: up to 20 seconds, 640px maximum, 10 fps." : "Preview plays the original selected interval. Generate an encoded preview to inspect export quality and exact file size.").font(.caption).foregroundStyle(.secondary)
            if let output = hub.previewResult?.outputs.first { Button("Play encoded result") { QuickLookController.shared.show(output) } }
        }
    }
    private var transcriptionOptions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Create a separate saved meeting transcript for each selected audio or video file.")
            SpeechModelView(hub: hub)
            Text("Audio stays on this Mac. Existing recordings and transcripts remain available even if transcription fails.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func resultDetails(_ result: ActionResult) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(result.outputs.enumerated()), id: \.offset) { _, url in
                HStack {
                    Text(url.lastPathComponent).lineLimit(1)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), countStyle: .file)).monospacedDigit()
                    Button("Save…") { saveCopy(url) }
                }.font(.caption).onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            }
            ForEach(Array(result.messages.enumerated()), id: \.offset) { _, message in Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }.padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
    private var bottomBar: some View {
        HStack {
            Button("Back to files") { hub.route = .fileActions }
            Spacer()
            if hub.previewBusy { ProgressView().controlSize(.small); Button("Cancel preview") { hub.discardPreview() } }
            else if kind == .rename { Button("Apply rename", action: hub.enqueue).buttonStyle(.borderedProminent).disabled(!renameValid) }
            else if kind == .transcribe { Button("Save & transcribe meetings", action: hub.enqueue).buttonStyle(.borderedProminent) }
            else {
                if hub.previewResult != nil {
                    Button("Refresh preview", action: generate).disabled(hub.isRecording)
                    Button("Keep results", action: hub.keepPreview).buttonStyle(.borderedProminent)
                } else {
                    if kind != .summarize { Button(hub.isRecording ? "Queue for later" : "Run in background", action: hub.enqueue) }
                    Button(kind == .summarize ? "Generate summary" : kind == .duplicates ? "Compare files" : "Generate preview", action: generate).buttonStyle(.borderedProminent).disabled(hub.isRecording)
                }
            }
        }
    }
    private var renameValid: Bool { (try? RenameCoordinator.preview(hub.editorInputs, settings: hub.settings)) != nil }
    private func generate() { if kind == .summarize { hub.summarizeFiles() } else { hub.generatePreview() } }
}

struct ImageCanvas: View {
    let url: URL
    @State private var zoom = 1.0
    @State private var image: NSImage?
    @State private var dimensions = ""
    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    if let image {
                        let fit = CropGeometry.imageFrame(size: image.size, in: geometry.size, inset: 12)
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: fit.width * zoom, height: fit.height * zoom)
                            .background(Checkerboard())
                            .frame(width: max(geometry.size.width, fit.width * zoom), height: max(geometry.size.height, fit.height * zoom))
                    }
                }.background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14)).clipShape(RoundedRectangle(cornerRadius: 14))
            }
            if !dimensions.isEmpty { Text(dimensions).font(.caption2).foregroundStyle(.secondary) }
            Slider(value: $zoom, in: 0.5...4).accessibilityLabel("Image zoom")
        }.task(id: url) {
            image = nil; zoom = 1
            let preview = try? await Task.detached { try ImageProcessor.preview(url) }.value
            guard !Task.isCancelled else { return }
            if let preview {
                image = NSImage(data: preview.data)
                dimensions = "\(preview.width) × \(preview.height) · " + ByteCountFormatter.string(fromByteCount: preview.bytes, countStyle: .file)
            } else { dimensions = "Preview unavailable" }

        }
    }
}
struct Checkerboard: View {
    var body: some View { Canvas { context, size in
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.gray.opacity(0.08)))
        for y in 0..<Int(size.height / 12 + 1) { for x in 0..<Int(size.width / 12 + 1) where (x + y).isMultiple(of: 2) { context.fill(Path(CGRect(x: x * 12, y: y * 12, width: 12, height: 12)), with: .color(.gray.opacity(0.15))) } }
    } }
}
struct RenameEditor: View {
    @ObservedObject var hub: HubModel
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: HubUI.section) { HubFormField("Find") { TextField("Find", text: $hub.settings.find) }; HubFormField("Replace with") { TextField("Replace", text: $hub.settings.replacement) } }
            HStack(spacing: HubUI.section) { HubFormField("Prefix") { TextField("Prefix", text: $hub.settings.prefix) }; HubFormField("Suffix") { TextField("Suffix", text: $hub.settings.suffix) }; Toggle("Number", isOn: $hub.settings.numberFiles); Toggle("Date", isOn: $hub.settings.datePrefix) }
            switch preview {
            case .success(let items):
                List(Array(items.enumerated()), id: \.offset) { _, item in HStack { Text(item.0.name).lineLimit(1); Spacer(); Image(systemName: "arrow.right"); Spacer(); Text(item.1.lastPathComponent).lineLimit(1).foregroundStyle(Color.accentColor) } }
            case .failure(let error): Text(error.localizedDescription).foregroundStyle(.orange)
            }
            Text("Apply changes the original filenames. Undo is available in Activity.").font(.caption).foregroundStyle(.secondary)
        }.textFieldStyle(.roundedBorder).frame(maxHeight: .infinity)
    }
    private var preview: Result<[(FileDescriptor, URL)], any Error> { Result { try RenameCoordinator.preview(hub.editorInputs, settings: hub.settings) } }
}

struct PDFOptions: View {
    @ObservedObject var hub: HubModel
    let kind: FileActionKind
    @State private var document: PDFDocument?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if kind == .mergePDF || kind == .makePDF {
                Text("Output order").font(.headline)
                ForEach(Array(hub.editorInputs.enumerated()), id: \.element.id) { index, file in
                    HStack {
                        Text(file.name).font(.caption).lineLimit(2)
                        Spacer()
                        Button { if index > 0 { hub.editorInputs.swapAt(index, index - 1) } } label: { Image(systemName: "arrow.up") }.disabled(index == 0).accessibilityLabel("Move file earlier")
                        Button { if index + 1 < hub.editorInputs.count { hub.editorInputs.swapAt(index, index + 1) } } label: { Image(systemName: "arrow.down") }.disabled(index + 1 == hub.editorInputs.count).accessibilityLabel("Move file later")
                    }
                }
            } else {
                if kind == .editPDF { Toggle("One PDF per selected page", isOn: $hub.settings.splitPages) }
                HubFormField("Pages in output order") { TextField("e.g. 1,3-5,2", text: $hub.settings.pages).help("Leave empty to include all pages") }
                Text("List pages in output order. Omit pages to remove them. Generate preview before keeping the result.").font(.caption).foregroundStyle(.secondary)
                HubFormField("Rotate pages") { Picker("Rotate pages", selection: $hub.settings.rotation) { ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) } }.labelsHidden() }
            }
            if kind == .compressPDF {
                Text("Image-based compression flattens text, links, and annotations. Review page quality before saving.").font(.caption).foregroundStyle(.orange)
                Slider(value: $hub.settings.quality, in: 0.1...1).accessibilityLabel("PDF image quality")
            }
            if let document {
                Text("\(document.pageCount) source pages").font(.caption)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())]) {
                    ForEach(0..<min(document.pageCount, 500), id: \.self) { index in
                        if let page = document.page(at: index) {
                            Button {
                                let component = String(index + 1)
                                hub.settings.pages += hub.settings.pages.isEmpty ? component : "," + component
                            } label: { VStack { Image(nsImage: page.thumbnail(of: CGSize(width: 85, height: 110), for: .mediaBox)).resizable().scaledToFit().frame(height: 85); Text("\(index + 1)").font(.caption2) } }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }.task(id: hub.editorInputs.first?.id) { if let url = hub.editorInputs.first?.url { document = PDFDocument(url: url) } }
    }
}

extension Collection { subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil } }

struct ArchiveContentsView: View {
    let url: URL
    @State private var entries: [ArchiveEntryInfo] = []
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(entries.count) entries").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in HStack { Image(systemName: entry.directory ? "folder" : "doc"); Text(entry.path).lineLimit(2); Spacer(); Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)).foregroundStyle(.secondary) }.font(.caption) }
            if !error.isEmpty { Text(error).foregroundStyle(.orange).font(.caption) }
        }.task(id: url) { do { entries = try await Task.detached { try ActionExecutor.archiveContents(url) }.value } catch { self.error = error.localizedDescription } }
    }
}
