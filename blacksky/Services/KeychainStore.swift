import Foundation
import Security

protocol CredentialStore: Sendable {
    func load() throws -> OAuthSession?
    func save(_ session: OAuthSession) throws
    func delete() throws
}

enum CredentialStoreError: Error, Equatable, LocalizedError, Sendable {
    case keychain(OSStatus)
    case encoding
    case decoding

    var errorDescription: String? {
        switch self {
        case .keychain: return "보안 저장소에 접근할 수 없습니다."
        case .encoding, .decoding: return "보안 저장소의 세션을 읽을 수 없습니다."
        }
    }
}

struct KeychainStore: CredentialStore, Sendable {
    private let service: String
    private let account: String

    init(service: String = "com.blacksky.oauth", account: String = "oauth-session") {
        self.service = service
        self.account = account
    }

    func load() throws -> OAuthSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        guard let data = result as? Data else { throw CredentialStoreError.decoding }
        do {
            return try JSONDecoder().decode(OAuthSession.self, from: data)
        } catch {
            throw CredentialStoreError.decoding
        }
    }

    func save(_ session: OAuthSession) throws {
        guard let data = try? JSONEncoder().encode(session) else {
            throw CredentialStoreError.encoding
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound { throw CredentialStoreError.keychain(updateStatus) }
        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CredentialStoreError.keychain(addStatus) }
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }
}

final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: OAuthSession?
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    func load() throws -> OAuthSession? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func save(_ session: OAuthSession) throws {
        lock.lock(); defer { lock.unlock() }
        value = session
        saveCount += 1
    }

    func delete() throws {
        lock.lock(); defer { lock.unlock() }
        value = nil
        deleteCount += 1
    }
}
