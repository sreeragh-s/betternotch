import Foundation
import SortMyMacCore

// An optional Codex command hook. Silence means "use Codex's normal flow" on every failure.
// stdout is reserved for the documented PermissionRequest decision; never log chat contents.
let arguments = CommandLine.arguments
let store: CodexBridgeStore
if let index = arguments.firstIndex(of: "--root"), arguments.indices.contains(index + 1) {
    store = CodexBridgeStore(root: URL(fileURLWithPath: arguments[index + 1]))
} else { store = .standard }
do {
    guard store.isAvailable() else { exit(0) }
    var data = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: 65_536), !chunk.isEmpty {
        data.append(chunk)
        if data.count > CodexBridgeStore.maximumBytes { exit(0) }
    }
    guard let event = try CodexEvent.hook(data) else { exit(0) }
    try store.publish(event)
    guard event.kind == .approval else { exit(0) }
    var outcome = "Continue in Codex"
    while event.isPending(), store.isAvailable() {
        if let decision = store.decision(for: event) {
            if let output = try decision.hookOutput() {
                try FileHandle.standardOutput.write(contentsOf: output + Data([10]))
            }
            outcome = decision.choice == .allow ? "Allowed once" : decision.choice == .deny ? "Declined" : "Continue in Codex"
            break
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    store.removeResponse(for: event)
    try store.publish(CodexEvent(kind: .resolved, threadID: event.threadID, turnID: event.turnID, title: outcome, resolvesID: event.id, resolution: outcome))
} catch { exit(0) }
