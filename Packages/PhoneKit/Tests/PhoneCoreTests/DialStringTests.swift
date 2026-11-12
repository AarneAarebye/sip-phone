// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import XCTest
@testable import PhoneCore

final class DialStringTests: XCTestCase {
    func testDialableTable() {
        let cases: [(String, String?)] = [
            ("030 1234", "0301234"),
            ("+49 (0)30 1234", "+49301234"),
            ("+49(0)30-1234", "+49301234"),
            ("+49\u{00A0}(0)\u{00A0}30\u{00A0}1234", "+49301234"),
            ("(030) 12-34", "0301234"),
            ("030/123.4", "0301234"),
            ("\n 030 1234 \r\n", "0301234"),
            ("*31#030 1234", "*31#0301234"),
            ("**610", "**610"),
            ("x@evil.example;transport=tcp", nil),
            ("030 1234@evil.example", nil),
            ("030\n1234", nil),           // a newline inside a number is not formatting
            ("030\t1234", nil),
            ("0301234;user=phone", nil),
            ("+", nil),
            ("++49301234", nil),
            ("49+301234", nil),
            ("", nil),
            ("   ", nil),
            ("anonymous", nil),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(DialString.dialable(input), expected, "input: \(input.debugDescription)")
        }
    }

    func testTrunkZeroOnlyRemovedAfterCountryCode() {
        XCTAssertEqual(DialString.clean("030 (0) 1234"), "03001234")   // not after +cc: just formatting
        XCTAssertEqual(DialString.clean("+49 (0)30 1234"), "+49301234")
    }

    func testNormalizeHandlesTrunkZeroAndNewlines() {
        XCTAssertEqual(NumberMatcher.normalize("+49 (0)30 1234"), "49301234")
        XCTAssertEqual(NumberMatcher.normalize("030 1234\n"), "49301234")
        XCTAssertEqual(NumberMatcher.normalize("\n+49 30 1234"), "49301234")
        XCTAssertTrue(NumberMatcher.matches("+49 (0)30 1234", "030 1234"))
    }
}
