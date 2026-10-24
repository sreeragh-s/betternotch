import AppKit
import Combine
import Security
import SwiftUI

@MainActor
final class SettingsStore: ObservableObject {
    @Published var displayID: String { didSet { defaults.set(displayID, forKey: "displayID") } }
    @Published var hoverDelay: Double { didSet { defaults.set(hoverDelay, forKey: "hoverDelay") } }
    @Published var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }
    @Published var accountID: String { didSet { defaults.set(accountID, forKey: "accountID") } }
    @Published var completedSetup: Bool { didSet { defaults.set(completedSetup, forKey: "completedSetup") } }
    @Published var token: String
    @Published var credentialMessage = ""
    private let defaults = UserDefaults.standard

    init() {
        displayID = UserDefaults.standard.string(forKey: "displayID") ?? "automatic"
        hoverDelay = UserDefaults.standard.object(forKey: "hoverDelay") as? Double ?? 0.3
        haptics = UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true
        accountID = UserDefaults.standard.string(forKey: "accountID") ?? ""
        completedSetup = UserDefaults.standard.bool(forKey: "completedSetup")
        token = (try? Keychain.read()) ?? ""
    }

    func saveToken() {
        do {
            try Keychain.write(token.trimmingCharacters(in: .whitespacesAndNewlines))
            credentialMessage = token.isEmpty ? "Token removed from Keychain." : "Token saved in Keychain."
        } catch { credentialMessage = error.localizedDescription }
    }
}

enum Keychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.sortmymac.app.cloudflare",
         kSecAttrAccount as String: "workers-ai"]
    }
    static func read() throws -> String {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw keychainError(status) }
        return value
    }
    static func write(_ value: String) throws {
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw keychainError(added) }
        } else if status != errSecSuccess { throw keychainError(status) }
    }
    private static func keychainError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey:
            "Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "could not save credentials")"])
    }
}
