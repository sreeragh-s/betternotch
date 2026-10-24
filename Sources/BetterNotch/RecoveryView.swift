import AppKit
import BetterNotchCore
import SwiftUI

struct RecoveryView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section {
                Text("Undo restores files to their original paths. Changed destinations and occupied paths are preserved for your review.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Refresh history") { Task { await model.refreshHistory() } }
                    .disabled(model.isBusy)
            }
            if model.moveRecords.isEmpty {
                Section { ContentUnavailableView("No moves yet", systemImage: "arrow.uturn.backward", description: Text("Your move history appears here after you drop folders into Finder.")) }
            }
            ForEach(model.moveRecords) { record in
                Section {
                    HStack {
                        Image(systemName: record.status == .undone ? "arrow.uturn.backward.circle" : (record.status.needsAttention ? "exclamationmark.triangle" : "folder.fill"))
                            .foregroundStyle(record.status.needsAttention ? Color.orange : Color.accentColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.name).font(.headline)
                            Text("\(record.items.count) files · \(record.status.rawValue.capitalized)").font(.caption).foregroundStyle(.secondary)
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
                                if let error = item.error { Text(error).font(.caption).foregroundStyle(.orange) }
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }
        }.formStyle(.grouped).task { await model.refreshHistory() }
    }
}
