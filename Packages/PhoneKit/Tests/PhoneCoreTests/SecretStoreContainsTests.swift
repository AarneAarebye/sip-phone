// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 SIP Phone contributors

import XCTest
@testable import PhoneCore

private final class MemorySecrets: SecretStore, @unchecked Sendable {
    var values: [String: String] = [:]
    func get(_ key: String) -> String? { values[key] }
    func contains(_ key: String) -> Bool { values[key] != nil }
    func set(_ value: String?, for key: String) throws { values[key] = value }
}

final class SecretStoreContainsTests: XCTestCase {
    func testContainsSemantics() throws {
        let s = MemorySecrets()
        XCTAssertFalse(s.contains("unknown"))
        try s.set("x", for: SecretKey.wireguardConfig)
        XCTAssertTrue(s.contains(SecretKey.wireguardConfig))
        try s.set(nil, for: SecretKey.wireguardConfig)
        XCTAssertFalse(s.contains(SecretKey.wireguardConfig))
    }
}
