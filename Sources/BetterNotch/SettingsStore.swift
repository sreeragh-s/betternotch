import AppKit
import Combine
import Security
import LocalAuthentication
import SwiftUI
import BetterNotchCore

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
        if Bundle.main.bundleIdentifier == AppIdentity.bundleIdentifier && !ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            AppIdentity.migratePreferences(defaults: .standard, to: AppIdentity.bundleIdentifier)
        }
        displayID = UserDefaults.standard.string(forKey: "displayID") ?? "automatic"
        hoverDelay = UserDefaults.standard.object(forKey: "hoverDelay") as? Double ?? 0.3
        haptics = UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true
        accountID = UserDefaults.standard.string(forKey: "accountID") ?? ""
        completedSetup = UserDefaults.standard.bool(forKey: "completedSetup")
        token = ""
        if !ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            Task { [weak self] in
                let saved = try? await Task.detached { try Keychain.read() }.value
                if self?.token.isEmpty == true { self?.token = saved ?? "" }
            }
        }
    }

    func saveToken() {
        do {
            try Keychain.write(token.trimmingCharacters(in: .whitespacesAndNewlines))
            credentialMessage = token.isEmpty ? "Token removed from Keychain." : "Token saved in Keychain."
        } catch { credentialMessage = error.localizedDescription }
    }
}

enum Keychain {
    private static func query(service: String = AppIdentity.keychainService) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "workers-ai"]
    }
    static func read() throws -> String {
        if let value = try read(service: AppIdentity.keychainService) { return value }
        return try read(service: AppIdentity.legacyKeychainService) ?? ""
    }
    private static func read(service: String) throws -> String? {
        var lookup = query(service: service)
        lookup[kSecReturnData as String] = true
        let authentication = LAContext(); authentication.interactionNotAllowed = true
        lookup[kSecUseAuthenticationContext as String] = authentication
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw keychainError(status) }
        return value
    }
    static func write(_ value: String) throws {
        if value.isEmpty {
            for service in [AppIdentity.keychainService, AppIdentity.legacyKeychainService] {
                let status = SecItemDelete(query(service: service) as CFDictionary)
                guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
            }
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query()
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
