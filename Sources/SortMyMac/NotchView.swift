import AppKit
import SortMyMacCore
import SwiftUI

struct NotchSurface: Shape {
    func path(in r: CGRect) -> Path {
        let wing: CGFloat = min(14, r.height / 3)
        let corner: CGFloat = min(25, r.height / 2)
        return Path { p in
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: r.width, y: 0))
            p.addQuadCurve(to: CGPoint(x: r.width - wing, y: wing), control: CGPoint(x: r.width - wing, y: 0))
            p.addLine(to: CGPoint(x: r.width - wing, y: r.height - corner))
            p.addQuadCurve(to: CGPoint(x: r.width - wing - corner, y: r.height), control: CGPoint(x: r.width - wing, y: r.height))
            p.addLine(to: CGPoint(x: wing + corner, y: r.height))
            p.addQuadCurve(to: CGPoint(x: wing, y: r.height - corner), control: CGPoint(x: wing, y: r.height))
            p.addLine(to: CGPoint(x: wing, y: wing))
            p.addQuadCurve(to: .zero, control: CGPoint(x: wing, y: 0))
            p.closeSubpath()
        }
    }
}

struct SoftPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct CircleControl: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.75)).frame(width: 30, height: 30)
                .background(.white.opacity(hover ? 0.14 : 0.04), in: Circle())
        }
        .buttonStyle(SoftPress()).onHover { hover = $0 }.help(label).accessibilityLabel(label)
    }
}

struct NotchView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchSurface().fill(.black)
                    .overlay(NotchSurface().stroke(.white.opacity(model.expanded ? 0.10 : 0), lineWidth: 1))
                if model.contentVisible {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 8) {
                            Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.mint)
                            Text("SortMyMac").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            CircleControl(symbol: "gearshape", label: "Settings", action: model.showSettings)
                            CircleControl(symbol: "xmark", label: "Close") { model.notch?.collapse(force: true) }
                        }
                        intake
                        HStack {
                            Text(model.status).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
                            Spacer(minLength: 4)
                            if model.phase == .analyzing {
                                ProgressView().controlSize(.small)
                                Button("Cancel", action: model.cancelOrganization).buttonStyle(.bordered)
                            } else if !model.files.isEmpty {
                                Button("Organize", action: model.organize).buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black)
                                    .disabled(model.isBusy)
                            }
                        }
                        if let warning = model.warnings.first {
                            Text(warning).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2).help(model.warnings.joined(separator: "\n"))
                        }
                    }
                    .padding(.horizontal, 36).padding(.top, model.geometry.restingSize.height + 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                } else if !model.geometry.hasCutout && !model.expanded {
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.mint)
                        Text("SortMyMac").font(.system(size: 10, weight: .medium))
                    }.padding(.top, 8)
                }
            }
            .frame(width: model.expanded ? model.geometry.expandedSize.width : model.geometry.restingSize.width,
                   height: model.expanded ? model.geometry.expandedSize.height : model.geometry.restingSize.height)
            .clipShape(NotchSurface()).compositingGroup()
            .shadow(color: .black.opacity(model.expanded ? 0.55 : 0), radius: 3, y: 1)
            .shadow(color: .black.opacity(model.expanded ? 0.38 : 0), radius: 14, y: 7)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white).environment(\.colorScheme, .dark)
    }
    private var intake: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.files.isEmpty ? "A little order. Right here." : "\(model.files.count) files. New possibilities.")
                    .font(.system(size: 22, weight: .semibold))
                Spacer()
                if !model.files.isEmpty {
                    CircleControl(symbol: "plus", label: "Add files", action: model.chooseFiles).disabled(model.isBusy)
                    CircleControl(symbol: "trash", label: "Clear session", action: model.clear).disabled(model.isBusy)
                }
            }
            Group {
                if model.files.isEmpty {
                    Button(action: model.chooseFiles) {
                        VStack(spacing: 9) {
                            Image(systemName: "tray.and.arrow.down").font(.system(size: 25)).foregroundStyle(.mint)
                            Text(model.dropTargeted ? "Drop to Organize" : "Drop files here or click to choose")
                                .font(.system(size: 13, weight: .medium))
                            Text("Group by topic. Move folders anywhere.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Choose files to organize")
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(model.files) { file in
                                VStack(spacing: 7) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path)).resizable().frame(width: 36, height: 36)
                                    Text(file.name).font(.system(size: 10)).lineLimit(1).frame(width: 78)
                                }.frame(width: 82, height: 88).help(file.name)
                                .contextMenu {
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                                    Button("Remove from session") { model.remove(file.id) }.disabled(model.isBusy)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }.padding(.horizontal, 12)
                    }
                }
            }
            .frame(height: 112)
            .background(.mint.opacity(model.dropTargeted ? 0.12 : 0.025), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(model.dropTargeted ? .mint : .white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
        }
    }

}
