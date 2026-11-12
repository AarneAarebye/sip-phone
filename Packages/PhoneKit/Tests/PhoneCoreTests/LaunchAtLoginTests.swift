// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 SIP Phone contributors

import XCTest
@testable import PhoneCore

final class LaunchAtLoginTests: XCTestCase {
    func testActionMatrix() {
        let expected: [(Bool, LoginItemStatus, LoginItemAction)] = [
            (true, .notRegistered, .register), (true, .enabled, .none),
            (true, .requiresApproval, .register), (true, .notFound, .register),
            (false, .notRegistered, .none), (false, .enabled, .unregister),
            (false, .requiresApproval, .unregister), (false, .notFound, .none),
        ]
        XCTAssertEqual(expected.count, 2 * LoginItemStatus.allCases.count)
        for (d, s, a) in expected { XCTAssertEqual(LaunchAtLogin.action(desired: d, status: s), a, "\(d) \(s)") }
    }
    func testIsOn() {
        XCTAssertEqual(LoginItemStatus.allCases.filter(LaunchAtLogin.isOn), [.enabled, .requiresApproval])
    }
}
