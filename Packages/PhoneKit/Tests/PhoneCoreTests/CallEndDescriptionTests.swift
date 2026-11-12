// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 SIP Phone contributors

import XCTest
@testable import PhoneCore

final class CallEndDescriptionTests: XCTestCase {
    private struct Row { let code: Int; let reason: String; let incoming: Bool; let connected: Bool; let local: Bool; let text: String; let error: Bool }
    func testTable() {
        let rows: [Row] = [
            Row(code: 603, reason: "Decline", incoming: false, connected: true, local: true, text: "Call ended", error: false),
            Row(code: 603, reason: "Decline", incoming: true, connected: true, local: true, text: "Call ended", error: false),
            Row(code: 200, reason: "OK", incoming: false, connected: true, local: false, text: "Call ended by the other party", error: false),
            Row(code: 200, reason: "OK", incoming: true, connected: true, local: false, text: "Call ended by the other party", error: false),
            Row(code: 603, reason: "Decline", incoming: true, connected: false, local: true, text: "Call declined", error: false),
            Row(code: 487, reason: "Request Terminated", incoming: true, connected: false, local: false, text: "Missed call", error: false),
            Row(code: 487, reason: "Cancelled", incoming: false, connected: false, local: true, text: "Call cancelled", error: false),
            Row(code: 603, reason: "Decline", incoming: false, connected: false, local: false, text: "Declined by the other party", error: false),
            Row(code: 486, reason: "Busy Here", incoming: false, connected: false, local: false, text: "Busy", error: false),
            Row(code: 600, reason: "Busy Everywhere", incoming: false, connected: false, local: false, text: "Busy", error: false),
            Row(code: 404, reason: "Not Found", incoming: false, connected: false, local: false, text: "Not available", error: false),
            Row(code: 480, reason: "Unavailable", incoming: false, connected: false, local: false, text: "Not available", error: false),
            Row(code: 484, reason: "Address Incomplete", incoming: false, connected: false, local: false, text: "Not available", error: false),
            Row(code: 410, reason: "Gone", incoming: false, connected: false, local: false, text: "Not available", error: false),
            Row(code: 604, reason: "Does Not Exist", incoming: false, connected: false, local: false, text: "Not available", error: false),
            Row(code: 408, reason: "Timeout", incoming: false, connected: false, local: false, text: "No answer", error: false),
            Row(code: 504, reason: "Gateway Timeout", incoming: false, connected: false, local: false, text: "No answer", error: false),
            Row(code: 500, reason: "Server Error", incoming: false, connected: false, local: false, text: "Call failed: 500 Server Error", error: true),
            // edge cases
            Row(code: 200, reason: "OK", incoming: false, connected: false, local: false, text: "Call failed: 200 OK", error: true),
            Row(code: 999, reason: "", incoming: false, connected: false, local: false, text: "Call failed: 999", error: true),
        ]
        for r in rows {
            let d = CallEndDescription.describe(code: r.code, reason: r.reason, isIncoming: r.incoming, wasConnected: r.connected, endedLocally: r.local)
            XCTAssertEqual(d.text, r.text, "\(r)")
            XCTAssertEqual(d.isError, r.error, "\(r)")
        }
    }
    func testNormalHangupsNeverMentionDecline() {
        for incoming in [true, false] { for connected in [true, false] { for local in [true, false] {
            let d = CallEndDescription.describe(code: 603, reason: "Decline", isIncoming: incoming, wasConnected: connected, endedLocally: local)
            XCTAssertFalse(d.text.contains("Decline "), d.text)
            XCTAssertFalse(d.text.hasSuffix("Decline"), d.text)
        } } }
    }
}
