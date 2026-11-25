import Foundation
import RecorderCore
import Security

/// 宛先ごとの端末トークンの保管場所。
public protocol TokenStore: Sendable {
    func token(for destination: DestinationID) throws -> String?
    func setToken(_ token: String?, for destination: DestinationID) throws
}

/// Keychain 版。ロック中の送信でも読めるよう kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly にする。
/// （バックアップや機種変更では移らない。新しい端末ではトークンを発行し直す）
public struct KeychainTokenStore: TokenStore {
    private let service: String
    private let accessGroup: String?

    public init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func baseQuery(_ destination: DestinationID) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: destination.rawValue,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func token(for destination: DestinationID) throws -> String? {
        var query = baseQuery(destination)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func setToken(_ token: String?, for destination: DestinationID) throws {
        let query = baseQuery(destination)
        SecItemDelete(query as CFDictionary)
        guard let token else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [DestinationID: String] = [:]
    public init(_ tokens: [DestinationID: String] = [:]) { self.tokens = tokens }
    public func token(for destination: DestinationID) throws -> String? { lock.withLock { tokens[destination] } }
    public func setToken(_ token: String?, for destination: DestinationID) throws { lock.withLock { tokens[destination] = token } }
}
