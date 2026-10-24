import AppKit
import BetterNotchCore
import SwiftUI
import UniformTypeIdentifiers

private enum ImagePreviewMode: String, CaseIterable { case edit = "Edit", result = "Result", compare = "Compare" }
private enum CropAspect: String, CaseIterable {
    case free = "Free", original = "Original", square = "1:1", landscape = "4:3", portrait = "3:4", wide = "16:9", tall = "9:16"
    func ratio(original: CGSize) -> Double? {
        switch self {
        case .free: nil
        case .original: original.height > 0 ? original.width / original.height : nil
        case .square: 1
        case .landscape: 4.0 / 3
        case .portrait: 3.0 / 4
        case .wide: 16.0 / 9
        case .tall: 9.0 / 16
        }
    }
    var turned: Self { switch self { case .landscape: .portrait; case .portrait: .landscape; case .wide: .tall; case .tall: .wide; default: self } }
}

/// The image itself is the main control. Output and reusable presets are secondary.
struct ImageEditor: View {
    @ObservedObject var hub: HubModel
    @State private var index = 0
    @State private var sourceSize = CGSize.zero
    @State private var aspect: CropAspect = .free
    @State private var mode: ImagePreviewMode = .edit
    @State private var exportOptions = false
    @State private var presetOptions = false
    @State private var presetName = ""
    private var kind: FileActionKind { hub.editorKind ?? .cropImage }
    private var cropping: Bool { kind == .cropImage }
    private var file: FileDescriptor? { hub.editorInputs[safe: index] }
    private var output: URL? {
        guard let result = hub.previewResult, result.outputs.count == hub.editorInputs.count else { return nil }
        return result.outputs[safe: index]
    }
    private var displaySize: CGSize { hub.settings.rotation % 180 == 0 ? sourceSize : CGSize(width: sourceSize.height, height: sourceSize.width) }
    private var normalizedAspect: Double? { aspect.ratio(original: displaySize).flatMap { displaySize.width > 0 ? $0 * displaySize.height / displaySize.width : nil } }
    private var sourceCrop: CropSelection { CropSelection(x: hub.settings.cropX, y: 1 - hub.settings.cropY - hub.settings.cropHeight, width: hub.settings.cropWidth, height: hub.settings.cropHeight).clamped() }
    private var displayedCrop: Binding<CropSelection> {
        Binding(get: { sourceCrop.rotated(clockwise: hub.settings.rotation) }, set: { displayed in
            let crop = displayed.rotated(clockwise: -hub.settings.rotation).aligned(to: sourceSize)
            var settings = hub.settings
            settings.cropX = crop.x; settings.cropY = max(0, 1 - crop.maxY); settings.cropWidth = crop.width; settings.cropHeight = crop.height
            hub.settings = settings
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading
            toolbar
            if let preset = hub.pendingPreset { Text(preset.name + " · " + preset.steps.map { $0.kind.title }.joined(separator: " → ")).font(.caption).foregroundStyle(.secondary) }
            workspace.frame(maxWidth: .infinity, maxHeight: .infinity)
            information
            footer
        }
        .onChange(of: hub.settings) { _, _ in mode = .edit }
        .onChange(of: hub.editorInputs.map(\.id)) { _, _ in index = 0; sourceSize = .zero; aspect = .free; mode = .edit }
        .onChange(of: index) { _, _ in aspect = .free; mode = .edit }
    }
    private var heading: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(FileActionDefinition.available(for: hub.editorInputs).filter { [.cropImage, .resize, .compressImage, .convertImage, .removeBackground].contains($0.kind) }) { action in
                    Button { hub.open(action) } label: { Label(action.kind.title, systemImage: action.kind.symbol) }
                }
            } label: { Label(kind.title, systemImage: kind.symbol).font(.system(size: 20, weight: .semibold)) }
                .menuStyle(.borderlessButton).fixedSize()
            Text(file?.name ?? "Image").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if hub.editorInputs.count > 1 {
                Picker("Image", selection: $index) { ForEach(Array(hub.editorInputs.enumerated()), id: \.offset) { i, file in Text(file.name).tag(i) } }.labelsHidden().frame(maxWidth: 200)
            }
            if output != nil { Picker("Preview", selection: $mode) { ForEach(ImagePreviewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().pickerStyle(.segmented).frame(width: 210) }
        }
    }
    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: HubUI.related) { editingControls; Spacer(minLength: HubUI.related); exportControls }
            VStack(alignment: .leading, spacing: HubUI.related) { editingControls; HStack { Spacer(); exportControls } }
        }.hubPanel()
    }
    private var editingControls: some View {
        HStack(spacing: HubUI.related) {
            if cropping {
                Picker("Ratio", selection: $aspect) { ForEach(CropAspect.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.fixedSize()
                    .onChange(of: aspect) { _, _ in displayedCrop.wrappedValue = displayedCrop.wrappedValue.fitted(aspect: normalizedAspect) }
                Divider().frame(height: 20)
            } else if kind == .resize { resizeControls }
            else if kind == .compressImage { compressionControls }
            else if kind == .convertImage { formatPicker.fixedSize() }
            else if kind == .removeBackground { Text("Keep the foreground. Export with transparency.").font(.caption).foregroundStyle(.secondary) }
            if cropping || kind == .resize || kind == .convertImage {
                HubIconButton(title: "Rotate left", symbol: "rotate.left") { turn(-90) }
                HubIconButton(title: "Rotate right", symbol: "rotate.right") { turn(90) }
            }
            if cropping { Button("Reset") { resetCrop() } }
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var exportControls: some View {
        HStack(spacing: HubUI.gap) {
            Button { exportOptions.toggle() } label: { Label("Export · " + hub.settings.format.uppercased(), systemImage: "slider.horizontal.3") }
                .popover(isPresented: $exportOptions, arrowEdge: .bottom) { outputSettings.padding(HubUI.inset).frame(width: 320).hubControls() }
            Menu {
                Button("Save preset…") { presetOptions = true }
                if !hub.presets.isEmpty {
                    Menu("Append to preset") { ForEach(hub.presets) { preset in Button(preset.name) { hub.appendPresetStep(preset) } } }
                }
            } label: { Image(systemName: "ellipsis").frame(minWidth: 16, minHeight: 20) }.menuStyle(.borderedButton).fixedSize().accessibilityLabel("More image options")
                .popover(isPresented: $presetOptions) {
                    VStack(alignment: .leading, spacing: HubUI.section) { Text("Save image preset").font(.headline); HubFormField("Preset name") { TextField("Name", text: $presetName) }; HStack { Button("Cancel") { presetOptions = false }; Spacer(); Button("Save") { hub.savePreset(name: presetName); presetOptions = false }.buttonStyle(.borderedProminent).disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }.padding(HubUI.inset).frame(width: 300).hubControls()
                }
        }.fixedSize(horizontal: true, vertical: false)
    }
    @ViewBuilder private var workspace: some View {
        if let file {
            if mode == .compare, let output {
                HStack(spacing: 12) {
                    VStack(spacing: 6) { Text("Original").font(.caption).foregroundStyle(.secondary); ImageCanvas(url: file.url) }
                    VStack(spacing: 6) { Text("Result").font(.caption).foregroundStyle(.secondary); outputPreview(output) }
                }
            } else if mode == .result, let output { outputPreview(output) }
            else {
                InteractiveImageCanvas(url: file.url, rotation: hub.settings.rotation, crop: displayedCrop, cropping: cropping, aspect: normalizedAspect, sourceSize: $sourceSize)
            }
        } else { ContentUnavailableView("Choose an image", systemImage: "photo") }
    }
    @ViewBuilder private func outputPreview(_ url: URL) -> some View {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true { ImageCanvas(url: url) }
        else { FilePreview(url: url) }
    }
    private var information: some View {
        HStack(spacing: 12) {
            if cropping {
                Image(systemName: "cursorarrow.motionlines").foregroundStyle(.secondary)
                Text(mode == .edit ? "Drag to select · move inside · pull edges to resize" : "Return to Edit to adjust the crop").font(.caption).foregroundStyle(.secondary)
                Spacer()
                let pixels = sourceCrop.pixelRect(in: sourceSize)
                let turned = hub.settings.rotation % 180 != 0
                Text("\(Int(turned ? pixels.height : pixels.width)) × \(Int(turned ? pixels.width : pixels.height)) px").font(.caption.monospacedDigit())
            } else {
                Text(sourceSize.width > 0 ? "\(Int(sourceSize.width)) × \(Int(sourceSize.height)) px" : "Loading image…").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if let output {
                let bytes = Int64((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .overlay(alignment: .bottomLeading) { if hub.editorInputs.count > 1 && cropping { Text("Same relative crop applies to all \(hub.editorInputs.count) images.").font(.caption2).foregroundStyle(.secondary).offset(y: 15) } }
        .padding(.bottom, hub.editorInputs.count > 1 && cropping ? 16 : 0)
    }
    private var footer: some View {
        HStack {
            Button { hub.route = .fileActions } label: { Label("Files", systemImage: "chevron.left") }
            if hub.previewBusy { ProgressView().controlSize(.small); Button("Cancel") { hub.discardPreview() } }
            Spacer()
            if let result = hub.previewResult, !result.messages.isEmpty {
                Menu("\(result.messages.count) notices") { ForEach(Array(result.messages.enumerated()), id: \.offset) { _, message in Text(message) } }.fixedSize()
            }
            if let output { Button("Save as…") { saveCopy(output) } }
            Button("Preview") { preview() }.disabled(hub.previewBusy || hub.isRecording || file == nil)
            Button(hub.isRecording ? "Queue image" : copyLabel) { createCopy() }
                .buttonStyle(.borderedProminent).disabled(hub.previewBusy || file == nil)
                .keyboardShortcut(.return, modifiers: .command)
        }.controlSize(.large).hubActionBar()
    }
    private var copyLabel: String {
        if hub.editorInputs.count > 1 { return "Create copies" }
        switch kind { case .cropImage: return "Crop image"; case .resize: return "Resize image"; case .compressImage: return "Compress image"; case .removeBackground: return "Create cutout"; default: return "Convert image" }
    }
    private func preview() {
        hub.generatePreview()
        Task { await hub.previewTask?.value; if hub.previewResult != nil { mode = .result } }
    }
    private func createCopy() {
        if hub.isRecording { hub.enqueue(); return }
        Task { if hub.previewResult == nil { hub.generatePreview(); await hub.previewTask?.value }; if hub.previewResult != nil { hub.keepPreview() } }
    }
    private func turn(_ delta: Int) { hub.settings.rotation = (hub.settings.rotation + delta + 360) % 360; aspect = aspect.turned }
    private func resetCrop() { aspect = .free; var settings = hub.settings; settings.cropX = 0; settings.cropY = 0; settings.cropWidth = 1; settings.cropHeight = 1; settings.rotation = 0; hub.settings = settings }
    private var formatPicker: some View { Picker("Format", selection: $hub.settings.format) { ForEach(ImageProcessor.outputFormats, id: \.self) { Text($0.uppercased()).tag($0) } } }
    private var outputSettings: some View {
        VStack(alignment: .leading, spacing: HubUI.section) {
            Text("Export options").font(.headline)
            HubFormField("Output format") { formatPicker.labelsHidden() }
            if ["jpeg", "heic", "webp"].contains(hub.settings.format) {
                HubFormField("Quality") { HStack { Slider(value: $hub.settings.quality, in: 0.05...1).accessibilityLabel("Export quality"); Text("\(Int(hub.settings.quality * 100))%").monospacedDigit().frame(width: 40) } }
            }
            if hub.settings.format == "jpeg" { HubFormField("JPEG background") { Picker("Background", selection: $hub.settings.jpegBackground) { Text("White").tag("white"); Text("Black").tag("black") }.labelsHidden().pickerStyle(.segmented) } }
            Text("Creates a new image. Your original stays in place.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var resizeControls: some View {
        HStack(spacing: 8) {
            Picker("Size", selection: $hub.settings.resizeMode) { Text("Longest edge").tag("longest"); Text("Fit dimensions").tag("dimensions"); Text("Percent").tag("percent") }.fixedSize()
            if hub.settings.resizeMode == "percent" { TextField("Percent", value: $hub.settings.percent, format: .number).frame(width: 65); Text("%") }
            else {
                TextField("Width", value: $hub.settings.width, format: .number.grouping(.never)).frame(width: 70)
                if hub.settings.resizeMode == "dimensions" { Text("×"); TextField("Height", value: $hub.settings.height, format: .number.grouping(.never)).frame(width: 70) }
                Text("px").foregroundStyle(.secondary)
            }
            Image(systemName: "link").foregroundStyle(.secondary).help("Aspect ratio is preserved")
        }.font(HubUI.body).textFieldStyle(.roundedBorder)
    }
    private var compressionControls: some View {
        HStack(spacing: 8) {
            Text("Quality").font(.caption)
            Slider(value: $hub.settings.quality, in: 0.05...1).frame(width: 120).accessibilityLabel("Image quality")
            Text("\(Int(hub.settings.quality * 100))%").font(.caption.monospacedDigit()).frame(width: 32)
            Toggle("Size limit", isOn: Binding(get: { hub.settings.targetBytes > 0 }, set: { hub.settings.targetBytes = $0 ? 500_000 : 0 })).font(.caption).toggleStyle(.checkbox)
            if hub.settings.targetBytes > 0 { TextField("KB", value: Binding(get: { hub.settings.targetBytes / 1000 }, set: { hub.settings.targetBytes = max(1, $0) * 1000 }), format: .number.grouping(.never)).frame(width: 65).textFieldStyle(.roundedBorder); Text("KB").font(.caption) }
        }
    }
}

struct InteractiveImageCanvas: View {
    let url: URL
    let rotation: Int
    @Binding var crop: CropSelection
    let cropping: Bool
    let aspect: Double?
    @Binding var sourceSize: CGSize
    @State private var image: NSImage?
    @State private var error = ""
    @State private var gestureStart: CropSelection?
    @State private var gestureHandle: CropHandle?
    var body: some View {
        GeometryReader { geometry in
            let displaySize = rotation % 180 == 0 ? sourceSize : CGSize(width: sourceSize.height, height: sourceSize.width)
            let frame = CropGeometry.imageFrame(size: displaySize, in: geometry.size)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.025))
                if let image {
                    Checkerboard().frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
                    Image(nsImage: image).resizable().interpolation(.high)
                        .frame(width: rotation % 180 == 0 ? frame.width : frame.height, height: rotation % 180 == 0 ? frame.height : frame.width)
                        .rotationEffect(.degrees(Double(rotation))).position(x: frame.midX, y: frame.midY).allowsHitTesting(false)
                    if cropping { cropOverlay(frame) }
                } else if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.secondary).frame(width: geometry.size.width, height: geometry.size.height) }
                else { ProgressView().frame(width: geometry.size.width, height: geometry.size.height) }
            }.coordinateSpace(name: "imageCrop")
        }
        .task(id: url) {
            image = nil; error = ""
            do {
                let preview = try await Task.detached { try ImageProcessor.preview(url) }.value
                try Task.checkCancellation()
                sourceSize = CGSize(width: preview.width, height: preview.height); image = NSImage(data: preview.data)
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    private func cropOverlay(_ frame: CGRect) -> some View {
        let rect = crop.frame(in: frame)
        return ZStack(alignment: .topLeading) {
            Color.clear.frame(width: frame.width, height: frame.height).contentShape(Rectangle()).position(x: frame.midX, y: frame.midY)
                .gesture(drag(.new, in: frame))
                .onHover { if $0 { NSCursor.crosshair.set() } else { NSCursor.arrow.set() } }
            Path { path in path.addRect(frame); path.addRect(rect) }.fill(.black.opacity(0.6), style: FillStyle(eoFill: true)).allowsHitTesting(false)
            Color.clear.frame(width: rect.width, height: rect.height).contentShape(Rectangle()).position(x: rect.midX, y: rect.midY)
                .gesture(drag(crop.isFull ? .new : .move, in: frame))
                .onHover { if $0 { (crop.isFull ? NSCursor.crosshair : NSCursor.openHand).set() } else { NSCursor.arrow.set() } }
            Path { path in
                path.addRect(rect)
                for value in [1.0 / 3, 2.0 / 3] {
                    path.move(to: CGPoint(x: rect.minX + rect.width * value, y: rect.minY)); path.addLine(to: CGPoint(x: rect.minX + rect.width * value, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * value)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * value))
                }
            }.stroke(.white.opacity(0.65), lineWidth: 0.75).allowsHitTesting(false)
            ForEach(CropHandle.allCases.filter { $0 != .move && $0 != .new }, id: \.rawValue) { handle in
                RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: handle.isCorner ? 11 : (handle == .top || handle == .bottom ? 20 : 5), height: handle.isCorner ? 11 : (handle == .left || handle == .right ? 20 : 5))
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
                    .position(handle.point(in: rect)).gesture(drag(handle, in: frame))
                    .accessibilityLabel("Crop \(handle.rawValue) handle")
                    .accessibilityAdjustableAction { direction in
                        let point = handle.point(in: crop.frame(in: CGRect(x: 0, y: 0, width: 1, height: 1)))
                        let delta: Double = direction == .increment ? 0.01 : -0.01
                        crop = CropGeometry.drag(handle, initial: crop, start: point, current: CGPoint(x: point.x + delta, y: point.y + delta), aspect: aspect)
                    }
            }
        }.transaction { $0.animation = nil }
    }
    private func drag(_ handle: CropHandle, in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("imageCrop"))
            .onChanged { value in
                if gestureStart == nil { gestureStart = crop; gestureHandle = handle }
                guard let initial = gestureStart else { return }
                crop = CropGeometry.drag(gestureHandle ?? handle, initial: initial, start: CropGeometry.normalized(value.startLocation, in: frame), current: CropGeometry.normalized(value.location, in: frame), aspect: aspect)
            }
            .onEnded { _ in gestureStart = nil; gestureHandle = nil; NSCursor.arrow.set() }
    }
}
