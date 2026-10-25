import BetterNotchCore
import SwiftUI

struct OrganizationView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: HubUI.section) {
            HStack {
                Text("Organize").font(HubUI.title)
                Spacer()
                if !model.files.isEmpty {
                    Text("\(model.files.count) files").font(HubUI.caption).foregroundStyle(.secondary)
                }
            }
            if model.phase == .completed {
                OrganizationPlaceholder(title: "Folders ready in Finder", symbol: "checkmark.circle.fill", color: .green,
                                        detail: "\(model.exportMovedCount) files moved. Undo returns them to their original locations.") {
                    HStack(spacing: HubUI.gap) {
                        Button("Undo") { model.undoOrganization() }.disabled(!model.canUndoOrganization)
                        Button("Organize more…", action: model.chooseFiles).buttonStyle(.borderedProminent)
                    }
                }
            } else if model.phase == .receiving {
                VStack(spacing: HubUI.section) {
                    ProgressView(value: Double(model.progressCompleted), total: Double(max(1, model.progressTotal))).frame(maxWidth: 240)
                    Text(model.status).font(HubUI.body).foregroundStyle(.secondary)
                    Button("Cancel") { model.organizationStageTask?.cancel() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.files.isEmpty && model.organizationSession?.status != .attention {
                OrganizationPlaceholder(title: "Organize into subfolders", symbol: "folder.badge.gearshape", color: .blue,
                                        detail: "Move files here temporarily to organize them. Undo restores their original locations.") {
                    Button("Choose files…", action: model.chooseFiles).buttonStyle(.borderedProminent)
                }
            } else {
                GroupingReviewView(model: model).frame(maxHeight: .infinity, alignment: .top)
                Text(model.status).font(HubUI.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let warning = model.warnings.first {
                    Text(warning).font(HubUI.caption).foregroundStyle(.orange).lineLimit(2).help(warning)
                }
                actionBar
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var actionBar: some View {
        HStack(spacing: HubUI.gap) {
            switch model.phase {
            case .analyzing:
                ProgressView().controlSize(.small)
                Text("Grouping staged files…").font(HubUI.caption).foregroundStyle(.secondary)
            case .grouped:
                Label("Drag folders to Finder", systemImage: "folder.fill")
                    .font(HubUI.body.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, HubUI.related).frame(height: HubUI.control)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
                    .overlay { FolderDragHandle(groups: model.groups, model: model, label: "Drag all folders to Finder") }
            case .exporting:
                ProgressView().controlSize(.small)
                Text("Moving folders…").font(HubUI.caption).foregroundStyle(.secondary)
            case .failed:
                if model.organizationSession?.status != .attention { Button("Retry", action: model.organize).buttonStyle(.borderedProminent) }
                Button("Recovery", action: model.showRecovery)
            case .ready:
                Button("Organize", action: model.organize).buttonStyle(.borderedProminent)
            default: EmptyView()
            }
            Spacer()
            if model.organizationSession?.canUndo == true {
                Button { model.undoOrganization() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!model.canUndoOrganization).help("Return all files to their original folders")
            }
        }.hubActionBar()
    }
}

private struct OrganizationPlaceholder<Actions: View>: View {
    let title: String
    let symbol: String
    let color: Color
    let detail: String
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        VStack(spacing: HubUI.section) {
            Image(systemName: symbol).font(.system(size: 28, weight: .medium))
                .foregroundStyle(color).frame(width: 60, height: 60)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityHidden(true)
            VStack(spacing: HubUI.gap) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(detail).font(HubUI.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: 320)
            actions().fixedSize(horizontal: true, vertical: false)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
