import SwiftUI

/// Distinct colors identify destinations; titles and symbols also carry their meaning.
enum HomeCardPalette {
    case coral, blue, orange, purple, green, slate

    private var colors: (Color, Color) {
        switch self {
        case .coral: (Color(red: 0.87, green: 0.36, blue: 0.42), Color(red: 0.73, green: 0.24, blue: 0.32))
        case .blue: (Color(red: 0.29, green: 0.54, blue: 0.88), Color(red: 0.18, green: 0.40, blue: 0.75))
        case .orange: (Color(red: 1.0, green: 0.75, blue: 0.50), Color(red: 0.95, green: 0.61, blue: 0.34))
        case .purple: (Color(red: 0.61, green: 0.45, blue: 0.84), Color(red: 0.46, green: 0.31, blue: 0.69))
        case .green: (Color(red: 0.28, green: 0.60, blue: 0.48), Color(red: 0.16, green: 0.44, blue: 0.35))
        case .slate: (Color(red: 0.48, green: 0.53, blue: 0.59), Color(red: 0.34, green: 0.38, blue: 0.44))
        }
    }
    var foreground: Color { self == .orange ? Color(red: 0.25, green: 0.12, blue: 0.04) : .white }
    var gradient: LinearGradient { LinearGradient(colors: [colors.0, colors.1], startPoint: .topLeading, endPoint: .bottomTrailing) }
    var highContrastBackground: Color { self == .orange ? colors.0 : colors.1 }
}

struct HomeToolCard: View {
    let title: String
    let symbol: String
    let detail: String
    var count: Int? = nil
    var compact = false
    let palette: HomeCardPalette
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: compact ? 6 : 10) {
                HStack(alignment: .center) {
                    Image(systemName: symbol).font(.system(size: compact ? 18 : 20, weight: .semibold)).frame(height: compact ? 22 : 25)
                    Spacer(minLength: 4)
                    if let count { Text(count, format: .number).font(.system(size: compact ? 20 : 23, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .bold)).lineLimit(1).minimumScaleFactor(0.85)
                    Text(detail).font(.system(size: 10, weight: .medium)).foregroundStyle(palette.foreground.opacity(contrast == .increased ? 1 : 0.88)).lineLimit(1)
                }
            }
            .foregroundStyle(palette.foreground)
            .padding(compact ? 10 : 13).frame(maxWidth: .infinity, minHeight: compact ? 80 : 100, alignment: .leading)
            .background {
                if contrast == .increased { RoundedRectangle(cornerRadius: 15).fill(palette.highContrastBackground) }
                else { RoundedRectangle(cornerRadius: 15).fill(palette.gradient) }
            }
            .overlay(RoundedRectangle(cornerRadius: 15).fill(.white.opacity(hovered ? 0.08 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(hovered ? 0.28 : 0.12), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(SoftPress())
        .onHover { hovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title)
        .accessibilityValue(count.map { "\($0) · \(detail)" } ?? detail)
    }
}
