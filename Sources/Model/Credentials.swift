import Foundation
import Security

/// The proxy password, kept in this device's Keychain (never synced, readable after first unlock
/// so the proxy keeps working while the phone is locked).
enum Credentials {
    private static let service = Bundle.main.bundleIdentifier!
    private static let account = "proxy-password"

    struct KeychainError: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "Keychain error \(status)" }
    }

    static func loadOrCreate() throws -> String {
        if let existing = try load() { return existing }
        return try regenerate()
    }

    static func regenerate() throws -> String {
        let password = generate()
        try save(password)
        return password
    }

    private static func load() throws -> String? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    private static func save(_ password: String) throws {
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary
        SecItemDelete(query)
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: Data(password.utf8),
        ] as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// 24 base62 characters (~143 bits) from the system CSPRNG, unbiased via rejection sampling.
    private static func generate() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var out = ""
        while out.count < 24 {
            var byte: UInt8 = 0
            precondition(SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess, "CSPRNG unavailable")
            if byte < 248 { out.append(alphabet[Int(byte) % alphabet.count]) }
        }
        return out
    }
}
