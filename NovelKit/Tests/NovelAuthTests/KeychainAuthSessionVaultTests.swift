#if canImport(Security)
import Foundation
import NovelAuth
import Security
import Testing

@Suite("Keychain auth vault recovery")
struct KeychainAuthSessionVaultTests {
    @Test("a malformed record is removed and treated as signed out")
    func malformedRecordIsRemovedOnLoad() async throws {
        let service = "jp.fuminiwa.test.malformed-\(UUID().uuidString)"
        let account = "session"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data("not-a-valid-auth-record".utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let cleanupStatus = SecItemDelete(query as CFDictionary)
        #expect(cleanupStatus == errSecSuccess || cleanupStatus == errSecItemNotFound)
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        #expect(addStatus == errSecSuccess)
        defer { _ = SecItemDelete(query as CFDictionary) }

        let vault = KeychainAuthSessionVault(service: service, account: account)
        #expect(try await vault.load() == nil)

        var result: CFTypeRef?
        var readQuery = query
        readQuery.removeValue(forKey: kSecValueData as String)
        readQuery[kSecReturnData as String] = true
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)
        #expect(readStatus == errSecItemNotFound)
    }
}
#endif
