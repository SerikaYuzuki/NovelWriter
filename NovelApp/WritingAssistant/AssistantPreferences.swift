import Foundation
import Security

struct AssistantPreferences {
    let defaults: UserDefaults
    var endpoint: String {
        defaults.string(forKey: "assistant.endpoint") ?? "https://api.openai.com/v1/chat/completions"
    }

    var model: String {
        defaults.string(forKey: "assistant.model") ?? ""
    }

    func model(_ purpose: AssistantPurpose) -> String {
        defaults.string(forKey: "assistant.model.\(purpose.id)") ?? model
    }

    func prompt(_ purpose: AssistantPurpose) -> String {
        defaults.string(forKey: "assistant.prompt.\(purpose.id)") ?? purpose.defaultPrompt
    }

    func configuration(_ purpose: AssistantPurpose) throws -> AssistantConfiguration {
        try AssistantConfiguration(endpoint: endpoint, model: model(purpose), prompt: prompt(purpose))
    }

    func key(endpoint: URL) throws -> String {
        #if FUMINIWA_TEST_COMPOSITION
        throw AssistantError.credentialFailure
        #else
        var query = keyQuery(endpoint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw AssistantError.missingKey
        }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw AssistantError.credentialFailure }
        return key
        #endif
    }

    func saveKey(_ key: String, endpoint: URL) throws {
        #if FUMINIWA_TEST_COMPOSITION
        throw AssistantError.credentialFailure
        #else
        let query = keyQuery(endpoint)
        let values: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AssistantError.credentialFailure }
        } else if status != errSecSuccess {
            throw AssistantError.credentialFailure
        }
        #endif
    }

    func deleteKey(endpoint: URL) throws {
        #if FUMINIWA_TEST_COMPOSITION
        throw AssistantError.credentialFailure
        #else
        let status = SecItemDelete(keyQuery(endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AssistantError.credentialFailure }
        #endif
    }

    private func keyQuery(_ endpoint: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.serikayuzuki.fuminiwa.writing-assistant",
         kSecAttrAccount as String: endpoint.absoluteString,
         kSecAttrSynchronizable as String: false]
    }
}
