import Foundation
import Security

public enum KeychainStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
            return "钥匙串操作失败：\(message) (\(status))"
        case .invalidData:
            return "钥匙串中的密钥数据无法读取"
        }
    }
}

public struct KeychainStore: Sendable {
    public let service: String

    public init(service: String? = nil) {
        self.service = service
            ?? ProcessInfo.processInfo.environment["CLAUDE_SWITCH_KEYCHAIN_SERVICE"]
            ?? "com.claudeswitch.credentials"
    }

    public func credential(for profile: ProfileID) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile.rawValue,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidData
        }
        return value
    }

    public func setCredential(_ credential: String?, for profile: ProfileID) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile.rawValue
        ]

        guard let credential, !credential.isEmpty else {
            let status = SecItemDelete(identity as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainStoreError.unexpectedStatus(status)
            }
            return
        }

        let value = Data(credential.utf8)
        let update: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(identity as CFDictionary, update as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = value
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }
    }
}
