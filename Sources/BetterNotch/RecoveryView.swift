import AppKit
import BetterNotchCore
import SwiftUI

struct RecoveryView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section {
                Text("Organization Undo returns temporarily held and exported files to their original folders. Changed files and occupied paths are preserved for review. Earlier move/copy history is listed separately below.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Refresh history") { Task { await model.refreshHistory() } }
                    .disabled(model.isBusy)
            }
            ForEach(model.organizationSessions) { session in
                Section("Organization · \(session.created.formatted(date: .abbreviated, time: .shortened))") {
                    HStack {
                        Image(systemName: session.status == .undone ? "arrow.uturn.backward.circle" : "folder.fill").foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(session.files.count) files · \(session.status.title)").font(.headline)
                            Text(session.status == .completed ? "Moved to destination · Undo available" : session.status == .undone ? "Original locations restored" : "\(session.pendingFiles.count) files awaiting placement or restoration").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if session.status != .undone { Button("Open") { model.resumeOrganization(session) } }
                        Button("Undo") { model.undoOrganization(session.id) }.disabled(session.status == .undone || model.isBusy)
                    }
                    if let error = session.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    DisclosureGroup("Original and staged locations") {
                        ForEach(session.files) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.original.name).font(.system(size: 12, weight: .medium))
                                Text("Original: \(entry.original.url.path)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                Text("Staged: \(entry.stagingURL.path)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        ForEach(session.exports) { output in
                            Text("Destination: \(output.destination.path)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            if model.moveRecords.isEmpty && model.organizationSessions.isEmpty {
                Section { ContentUnavailableView("No exports yet", systemImage: "arrow.uturn.backward", description: Text("Moves and organized copies appear here after you drop folders into Finder.")) }
            }
            ForEach(model.moveRecords) { record in
                Section {
                    HStack {
                        Image(systemName: record.status == .undone ? "arrow.uturn.backward.circle" : (record.status.needsAttention ? "exclamationmark.triangle" : "folder.fill"))
                            .foregroundStyle(record.status.needsAttention ? Color.orange : Color.accentColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.name).font(.headline)
                            Text("\(record.movedCount) moved · \(record.copiedCount) copied · \(record.status.rawValue.capitalized)").font(.caption).foregroundStyle(.secondary)
                            Text(record.created, style: .date).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Show destination") { NSWorkspace.shared.activateFileViewerSelecting([record.folder]) }
                        Button(record.status.needsAttention ? "Recover / Undo" : "Undo") { model.undoMove(record.id) }
                            .disabled(record.status == .undone || model.isBusy)
                    }
                    if let error = record.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    DisclosureGroup("Files and original locations") {
                        ForEach(record.items) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.file.name).font(.system(size: 12, weight: .medium))
                                Text(item.file.url.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                Text("→ \(item.destination.path)").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                Text(item.operation == .copy ? "Copy · original kept" : "Move into subfolder").font(.caption2).foregroundStyle(.secondary)
                                if let error = item.error { Text(error).font(.caption).foregroundStyle(.orange) }
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }
        }.formStyle(.grouped).task { await model.refreshHistory() }
    }
}
