// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 SIP Phone contributors

import XCTest
@testable import SystemAdapters

final class PathChangeGateTests: XCTestCase {
    func testInitialCallbackIgnored() {
        var g = PathChangeGate()
        XCTAssertFalse(g.observe("en0+"))
    }
    func testChangeTriggersAndRepeatDoesNot() {
        var g = PathChangeGate()
        _ = g.observe("en0+")
        XCTAssertFalse(g.observe("en0+"))
        XCTAssertTrue(g.observe("en0,utun3+"))
        XCTAssertFalse(g.observe("en0,utun3+"))
        XCTAssertTrue(g.observe("en0-"))
    }
    func testSkipWhileConnectingVPN() {
        XCTAssertFalse(PathChangeGate.shouldReconnect(isConnectingVPN: true))
        XCTAssertTrue(PathChangeGate.shouldReconnect(isConnectingVPN: false))
    }
    func testSignature() {
        XCTAssertEqual(PathChangeGate.signature(interfaceNames: ["en0", "utun1"], satisfied: true), "en0,utun1+")
        XCTAssertEqual(PathChangeGate.signature(interfaceNames: [], satisfied: false), "-")
    }
    func testPowerInterpretation() {
        XCTAssertTrue(PowerSourceInterpreter.isOnAC(providingType: "AC Power", acValue: "AC Power"))
        XCTAssertFalse(PowerSourceInterpreter.isOnAC(providingType: "Battery Power", acValue: "AC Power"))
        XCTAssertFalse(PowerSourceInterpreter.isOnAC(providingType: nil, acValue: "AC Power"))
    }
}
