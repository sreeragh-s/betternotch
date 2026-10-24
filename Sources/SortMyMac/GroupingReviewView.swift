import AppKit
import SortMyMacCore
import SwiftUI

struct GroupingReviewView: View {
    @ObservedObject var model: AppModel
    @Namespace private var gathering
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var groupedIDs: Set<UUID> { Set(model.groups.flatMap(\.files).map(\.id)) }
    private var remaining: [FileDescriptor] { model.files.filter { !groupedIDs.contains($0.id) } }
    private var editing: Bool { model.phase == .grouped }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !remaining.isEmpty {
                    HStack(spacing: 7) {
                        ForEach(remaining.prefix(8)) { file in
                            fileIcon(file, size: 25)
                        }
                        if remaining.count > 8 { Text("+\(remaining.count - 8)").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text("Finding connections").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(8)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(model.groups) { group in
                        FolderCard(group: group, model: model, editing: editing) {
                            HStack(spacing: 5) {
                                ForEach(group.files.prefix(5)) { file in
                                    fileIcon(file, size: 22).contextMenu {
                                        if editing {
                                            Menu("Move to folder") {
                                                ForEach(model.groups.filter { $0.id != group.id }) { target in
                                                    Button(target.name) { model.reassign(file.id, to: target.id) }
                                                }
                                                Button("New folder") { model.separate(file.id) }
                                            }
                                        }
                                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                                    }
                                }
                                if group.files.count > 5 {
                                    Menu("+\(group.files.count - 5)") {
                                        ForEach(Array(group.files.dropFirst(5))) { file in
                                            Menu(file.name) {
                                                ForEach(model.groups.filter { $0.id != group.id }) { target in
                                                    Button("Move to \(target.name)") { model.reassign(file.id, to: target.id) }.disabled(!editing)
                                                }
                                                Button("New folder") { model.separate(file.id) }.disabled(!editing)
                                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                                            }
                                        }
                                    }.menuStyle(.borderlessButton).fixedSize().font(.system(size: 10))
                                    .anchorPreference(key: FolderDragExclusions.self, value: .bounds) { [$0] }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                if model.groups.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "sparkle.magnifyingglass").font(.system(size: 25)).foregroundStyle(Color.accentColor)
                        Text("Looking for what belongs together").font(.system(size: 12, weight: .medium))
                        Text("Your originals are still right where you left them.").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 18)
                }
            }.padding(2)
        }
        .frame(height: 178)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.5, dampingFraction: 0.8), value: model.groups)
        .accessibilityLabel(model.phase == .analyzing ? "Grouping files" : "Organized folders")
    }

    private func fileIcon(_ file: FileDescriptor, size: CGFloat) -> some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path)).resizable().frame(width: size, height: size)
            .matchedGeometryEffect(id: file.id, in: gathering, properties: reduceMotion ? [] : .frame)
            .help(file.name).accessibilityLabel(file.name)
    }
}

struct FolderCard<Files: View>: View {
    let group: FileGroup
    @ObservedObject var model: AppModel
    let editing: Bool
    @ViewBuilder let files: () -> Files
    @State private var name = ""
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").font(.system(size: 24)).foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    if editing {
                        TextField("Folder name", text: $name).textFieldStyle(.plain).font(.system(size: 12, weight: .semibold))
                            .onSubmit { model.rename(group.id, to: name) }
                            .onChange(of: name) { _, value in model.renameDraft(group.id, to: value) }
                            .onTapGesture { model.notch?.focusForEditing() }
                            .accessibilityLabel("Name for \(group.name)")
                            .anchorPreference(key: FolderDragExclusions.self, value: .bounds) { [$0] }
                    } else { Text(group.name).font(.system(size: 12, weight: .semibold)).lineLimit(1) }
                    Text("\(group.files.count) \(group.files.count == 1 ? "file" : "files")")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            files()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(hovered ? 0.09 : 0.045), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.accentColor.opacity(hovered ? 0.35 : 0.1), lineWidth: 1))
        .overlayPreferenceValue(FolderDragExclusions.self) { exclusions in
            if editing || model.phase == .exporting {
                GeometryReader { geometry in
                    FolderDragHandle(groups: [group], model: model, label: "Drag \(group.name) folder to Finder",
                                     passthroughRects: exclusions.map { geometry[$0] }, cornerRadius: 13,
                                     tracksCardMouseEvents: true)
                        .allowsHitTesting(false)
                }
            }
        }
        .onHover { hovered = $0 }
        .onAppear { name = group.name }
        .onChange(of: group.name) { _, value in if name != value { name = value } }
    }
}
