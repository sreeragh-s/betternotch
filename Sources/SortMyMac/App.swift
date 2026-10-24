import AppKit
import SwiftUI

@main
struct SortMyMacApp: App {
    var body: some Scene {
        WindowGroup("SortMyMac") {
            VStack(spacing: 16) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 48)).foregroundStyle(.mint)
                Text("A little order. Right at the notch.").font(.title2)
                Text("Your files, brought together.").foregroundStyle(.secondary)
            }
            .padding(48).frame(minWidth: 480, minHeight: 280)
        }
    }
}
