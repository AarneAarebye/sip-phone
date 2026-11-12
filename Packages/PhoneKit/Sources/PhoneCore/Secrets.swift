// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import Foundation
import Security

public protocol SecretStore: Sendable {
    func get(_ key: String) -> String?
    /// Whether a secret exists, answered without reading its value into memory.
    func contains(_ key: String) -> Bool
    func set(_ value: String?, for key: String) throws
}
public enum SecretKey {
    public static let sipPassword = "sipPassword"
    public static let tr064Password = "tr064Password"
    public static let wireguardConfig = "wireguardConfig"
}

public struct KeychainSecretStore: SecretStore {
    private let service: String
    public init(service: String = "SipPhone") { self.service = service }
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
    public func get(_ key: String) -> String? {
        var q = query(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    public func contains(_ key: String) -> Bool {
        var q = query(key); q[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }
    public func set(_ value: String?, for key: String) throws {
        SecItemDelete(query(key) as CFDictionary)
        guard let value else { return }
        var q = query(key); q[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
