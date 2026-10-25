import BetterNotchCore
import SwiftUI

enum FileDropDestination: String, CaseIterable {
    case shelf, organize
}

struct FileDropFrames: PreferenceKey {
    static let defaultValue: [FileDropDestination: CGRect] = [:]
    static func reduce(value: inout [FileDropDestination: CGRect], nextValue: () -> [FileDropDestination: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct FileDropView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: HubUI.section) {
            Text("Where should these files go?").font(HubUI.title)
            HStack(spacing: HubUI.related) {
                target(.shelf, title: "Shelf", symbol: "tray.and.arrow.down.fill", detail: "Keep files handy", color: .purple)
                target(.organize, title: "Organize", symbol: "folder.badge.gearshape", detail: model.isBusy ? "Organization in progress" : model.hasPendingOrganization ? "Finish or Undo current files" : model.dragFileCount > FileIntake.limit ? "Up to 50 files at a time" : "Move here & group", color: .blue)
            }
            Text("Shelf keeps references. Organize temporarily moves files here, with Undo. Topic grouping uses Cloudflare; screenshots stay local.")
                .font(HubUI.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .accessibilityElement(children: .contain)
    }
    private func target(_ destination: FileDropDestination, title: String, symbol: String, detail: String, color: Color) -> some View {
        let enabled = destination == .shelf || model.canOrganizeDrop
        let selected = enabled && model.dropChoice == destination
        return VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 32, weight: .medium)).foregroundStyle(enabled ? color : .secondary)
            VStack(spacing: 5) {
                Text(title).font(.system(size: 18, weight: .semibold))
                Text(detail).font(HubUI.caption).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(enabled ? Color.primary : Color.secondary)
        .frame(maxWidth: .infinity, minHeight: 160)
        .background(color.opacity(selected ? 0.24 : 0.10), in: RoundedRectangle(cornerRadius: HubUI.radius))
        .overlay(RoundedRectangle(cornerRadius: HubUI.radius).strokeBorder(enabled ? color.opacity(selected ? 1 : 0.35) : .gray.opacity(0.2), style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [5, 4])))
        .background(GeometryReader { geometry in
            Color.clear.preference(key: FileDropFrames.self, value: [destination: geometry.frame(in: .named("notchHost"))])
        })
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) drop target")
        .accessibilityValue(selected ? "Targeted" : enabled ? detail : "Unavailable")
    }
}
