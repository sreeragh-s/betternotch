import Foundation

public enum AppIdentity {
    public static let name = "BetterNotch"
    public static let bundleIdentifier = "com.betternotch.native"
    public static let keychainService = "com.betternotch.app.cloudflare"

    // Upgrade compatibility only. Never use these identifiers as visible branding.
    public static let legacyStorageName = "SortMyMac"
    public static let legacyBundleIdentifier = "com.sortmymac.native"
    public static let legacyKeychainService = "com.sortmymac.app.cloudflare"
    public static let legacyHookMarker = "--sortmymac-hook"

    /// Keep existing absolute audio/output references and trusted hook mailbox paths valid.
    /// New installations use BetterNotch; upgrades continue using their existing library.
    public static func supportRoot(in base: URL) -> URL {
        let legacy = base.appendingPathComponent(legacyStorageName, isDirectory: true)
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: legacy.path, isDirectory: &directory), directory.boolValue { return legacy }
        return base.appendingPathComponent(name, isDirectory: true)
    }

    /// Copy only app-owned preferences once, preserving every existing BetterNotch choice.
    public static func migratePreferences(defaults: UserDefaults, to domain: String, from legacyDomain: String = legacyBundleIdentifier) {
        let marker = "didImportLegacyPreferences"
        var current = defaults.persistentDomain(forName: domain) ?? [:]
        guard current[marker] as? Bool != true else { return }
        let legacy = defaults.persistentDomain(forName: legacyDomain) ?? [:]
        let keys = ["displayID", "hoverDelay", "haptics", "accountID", "completedSetup", "speechModel", "speechLanguage",
                    "ollamaEndpoint", "ollamaModel", "shortcutName", "codexNotchEnabled", "codexDesktopQuestions"]
        for key in keys where current[key] == nil { current[key] = legacy[key] }
        current[marker] = true
        defaults.setPersistentDomain(current, forName: domain)
    }
}
