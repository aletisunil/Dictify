import Foundation
import LocalAuthentication
import Security

final class KeychainManager: @unchecked Sendable {
    private let service = Constants.Keychain.service
    private let account = Constants.Keychain.apiKeyAccount
    private let defaults = UserDefaults.standard

    var hasStoredAPIKeyHint: Bool {
        defaults.bool(forKey: Constants.Keychain.hasAPIKeyDefaultsKey)
    }

    func saveAPIKey(_ key: String) -> Bool {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty, let data = normalizedKey.data(using: .utf8) else { return false }

        let query = noPromptKeychainQuery(service: service)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            setHasStoredAPIKeyHint(true)
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            Log.storage.error("Keychain update failed: OSStatus \(updateStatus)")
            return false
        }

        var addQuery = keychainQuery(service: service)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            Log.storage.error("Keychain add failed: OSStatus \(addStatus)")
        }
        if addStatus == errSecSuccess {
            setHasStoredAPIKeyHint(true)
        }
        return addStatus == errSecSuccess
    }

    func getAPIKey() -> String? {
        getAPIKey(service: service)
    }

    @discardableResult
    func delete() -> Bool {
        let status = SecItemDelete(noPromptKeychainQuery(service: service) as CFDictionary)
        let didDelete = status == errSecSuccess || status == errSecItemNotFound
        if didDelete {
            setHasStoredAPIKeyHint(false)
        } else {
            Log.storage.error("Keychain delete failed: OSStatus \(status)")
        }
        return didDelete
    }

    var hasAPIKey: Bool {
        guard let key = getAPIKey() else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @discardableResult
    func refreshStoredAPIKeyHint() -> Bool {
        let hasKey = hasAPIKey
        setHasStoredAPIKeyHint(hasKey)
        return hasKey
    }

    private func getAPIKey(service: String) -> String? {
        var query = noPromptKeychainQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                Log.storage.error("Keychain read failed: OSStatus \(status)")
            }
            return nil
        }
        let key = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == false ? key : nil
    }

    private func keychainQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func noPromptKeychainQuery(service: String) -> [String: Any] {
        var query = keychainQuery(service: service)
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    private func setHasStoredAPIKeyHint(_ hasKey: Bool) {
        defaults.set(hasKey, forKey: Constants.Keychain.hasAPIKeyDefaultsKey)
    }
}
