import Foundation
import Darwin

public enum CodexHookInstaller {
    public static let marker = "--betternotch-hook"
    private static func owns(_ command: String?) -> Bool {
        guard let command else { return false }
        return command.contains(marker) || command.contains(AppIdentity.legacyHookMarker)
    }
    private static let events = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "Interrupt", "SessionEnd"]
    public static func isInstalled(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = config["hooks"] as? [String: [[String: Any]]] else { return false }
        return hooks.values.joined().contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { owns($0["command"] as? String) }
        }
    }
    /// Preserve unrelated hook groups and handlers; back up the exact previous file on each edit.
    public static func update(at url: URL, helper: URL, inbox: URL, install: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard (existing?.count ?? 0) < 4_194_304 else { throw CocoaError(.fileReadTooLarge) }
        var config: [String: Any] = [:]
        if let existing {
            guard let decoded = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            config = decoded
        }
        if let raw = config["hooks"], !(raw is [String: [[String: Any]]]) { throw CocoaError(.fileReadCorruptFile) }
        var hooks = config["hooks"] as? [String: [[String: Any]]] ?? [:]
        for (event, groups) in hooks {
            hooks[event] = groups.compactMap { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                let retained = handlers.filter { !owns($0["command"] as? String) }
                guard !retained.isEmpty else { return nil }
                var result = group; result["hooks"] = retained; return result
            }
        }
        if install {
            func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let command = quote(helper.path) + " " + marker + " --root " + quote(inbox.path)
            for event in events {
                var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": event == "PermissionRequest" ? 95 : event == "Interrupt" || event == "SessionEnd" ? 2 : 5]]]
                if event == "PreToolUse" { group["matcher"] = "apply_patch|Edit|Write|request_user_input" }
                if event == "PostToolUse" { group["matcher"] = "apply_patch|Edit|Write|request_user_input" }
                hooks[event, default: []].append(group)
            }
        }
        config["hooks"] = hooks
        if let existing {
            try privateWrite(existing, to: url.appendingPathExtension("betternotch-backup-" + UUID().uuidString))
            guard try Data(contentsOf: url) == existing else { throw CocoaError(.fileWriteFileExists) }
        }
        let staging = url.deletingLastPathComponent().appendingPathComponent(".betternotch-hooks-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        try privateWrite(JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]), to: staging)
        guard rename(staging.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    private static func privateWrite(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: data); try file.synchronize(); try file.close()
    }
}
