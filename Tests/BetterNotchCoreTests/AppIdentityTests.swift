import Foundation
import Testing
@testable import BetterNotchCore

@Test func freshInstallsUseBrandedStorageAndUpgradesKeepExistingReferences() throws {
    let base = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    #expect(AppIdentity.supportRoot(in: base).lastPathComponent == "BetterNotch")
    let legacy = base.appendingPathComponent(AppIdentity.legacyStorageName, isDirectory: true)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    let recording = legacy.appendingPathComponent("saved-audio.wav")
    try Data([1, 2, 3]).write(to: recording)
    // An incidental new directory must not hide an existing library or its absolute URLs.
    try FileManager.default.createDirectory(at: base.appendingPathComponent("BetterNotch"), withIntermediateDirectories: true)
    #expect(AppIdentity.supportRoot(in: base) == legacy)
    #expect(try Data(contentsOf: recording) == Data([1, 2, 3]))
}

@Test func preferenceUpgradePreservesNewChoicesAndDoesNotReimportRemovedValues() throws {
    let target = "BetterNotch-Test-" + UUID().uuidString, legacy = "BetterNotch-Legacy-Test-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: target))
    defer { defaults.removePersistentDomain(forName: target); defaults.removePersistentDomain(forName: legacy) }
    defaults.setPersistentDomain(["hoverDelay": 0.7, "completedSetup": true, "codexNotchEnabled": true, "speechLanguage": "fr", "unrelated": "ignored"], forName: legacy)
    defaults.setPersistentDomain(["hoverDelay": 0.2, "speechModel": "base"], forName: target)
    AppIdentity.migratePreferences(defaults: defaults, to: target, from: legacy)
    #expect(defaults.double(forKey: "hoverDelay") == 0.2)
    #expect(defaults.bool(forKey: "completedSetup"))
    #expect(defaults.bool(forKey: "codexNotchEnabled"))
    #expect(defaults.string(forKey: "speechModel") == "base")
    #expect(defaults.string(forKey: "speechLanguage") == "fr")
    #expect(defaults.object(forKey: "unrelated") == nil)
    defaults.removeObject(forKey: "speechLanguage")
    AppIdentity.migratePreferences(defaults: defaults, to: target, from: legacy)
    #expect(defaults.object(forKey: "speechLanguage") == nil)
    #expect(defaults.persistentDomain(forName: legacy)?["completedSetup"] as? Bool == true)
}

@Test func renamedHookInstallerRecognizesAndReplacesLegacyHandlersWithoutDuplicates() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let hooks = root.appendingPathComponent("hooks.json")
    let original: [String: Any] = ["hooks": ["Stop": [["hooks": [
        ["type": "command", "command": "legacy-helper " + AppIdentity.legacyHookMarker],
        ["type": "command", "command": "echo unrelated"]
    ]]]]]
    try JSONSerialization.data(withJSONObject: original).write(to: hooks)
    #expect(CodexHookInstaller.isInstalled(at: hooks))
    try CodexHookInstaller.update(at: hooks, helper: root.appendingPathComponent("BetterNotchCodexBridge"), inbox: root.appendingPathComponent("inbox"), install: true)
    let installed = String(decoding: try Data(contentsOf: hooks), as: UTF8.self)
    #expect(!installed.contains(AppIdentity.legacyHookMarker))
    #expect(installed.contains(CodexHookInstaller.marker))
    #expect(installed.contains("echo unrelated"))
    try CodexHookInstaller.update(at: hooks, helper: root, inbox: root, install: false)
    #expect(!CodexHookInstaller.isInstalled(at: hooks))
    #expect(String(decoding: try Data(contentsOf: hooks), as: UTF8.self).contains("echo unrelated"))
}
