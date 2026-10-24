import SwiftUI

/// Shared metrics for the notch. Settings keeps the system's grouped Form layout.
enum HubUI {
    static let small: CGFloat = 4
    static let gap: CGFloat = 8
    static let related: CGFloat = 12
    static let section: CGFloat = 16
    static let inset: CGFloat = 24
    static let control: CGFloat = 32
    static let radius: CGFloat = 12
    static let title = Font.system(size: 20, weight: .semibold)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11)
}

private struct HubControls: ViewModifier {
    func body(content: Content) -> some View {
        content.font(HubUI.body)
            .buttonStyle(.bordered).controlSize(.large)
            .textFieldStyle(.roundedBorder).pickerStyle(.menu).menuStyle(.borderedButton).toggleStyle(.checkbox)
    }
}

private struct HubPanel: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content.padding(HubUI.section)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: HubUI.radius))
            .overlay(RoundedRectangle(cornerRadius: HubUI.radius).strokeBorder(.primary.opacity(contrast == .increased ? 0.35 : 0.09)))
    }
}

extension View {
    func hubControls() -> some View { modifier(HubControls()) }
    func hubPanel() -> some View { modifier(HubPanel()) }
    func hubActionBar() -> some View {
        padding(.top, HubUI.related).frame(minHeight: 44)
            .overlay(alignment: .top) { Divider() }
    }
}

/// Keep the label visible while the underlying native control owns focus and input.
struct HubFormField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: HubUI.gap) {
            Text(title).font(HubUI.caption.weight(.medium)).foregroundStyle(.secondary)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct HubIconButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).frame(minWidth: 16, minHeight: 20) }
            .buttonStyle(.bordered).controlSize(.large)
            .help(title).accessibilityLabel(title)
    }
}

struct HubSearchField: View {
    let title: String
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: HubUI.gap) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(title, text: $text).textFieldStyle(.plain).focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).frame(width: 24, height: 28).help("Clear search").accessibilityLabel("Clear search")
            }
        }.padding(.horizontal, HubUI.related).frame(minHeight: HubUI.control)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: focused ? 2 : 1))
    }
}
