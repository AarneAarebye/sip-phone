// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import XCTest
@testable import PhoneCore

final class NumberMatcherTests: XCTestCase {
    func testNormalizeInternationalAndNationalFormsAgree() {
        let expected = "49301234"
        XCTAssertEqual(NumberMatcher.normalize("+49 30 1234"), expected)
        XCTAssertEqual(NumberMatcher.normalize("030 1234"), expected)
        XCTAssertEqual(NumberMatcher.normalize("0049 30 1234"), expected)
        XCTAssertEqual(NumberMatcher.normalize("(030) 12-34"), expected)
    }
    func testNumberWithoutAreaCodeUsesConfiguredAreaCode() {
        XCTAssertEqual(NumberMatcher.normalize("1234", areaCode: "030"), "49301234")
        XCTAssertEqual(NumberMatcher.normalize("1234", areaCode: "30"), "49301234")
        XCTAssertEqual(NumberMatcher.normalize("1234"), "1234")
    }
    func testEmptyAndNonNumericNeverMatch() {
        XCTAssertEqual(NumberMatcher.normalize(""), "")
        XCTAssertEqual(NumberMatcher.normalize("anonymous"), "")
        XCTAssertFalse(NumberMatcher.matches("", ""))
    }
    func testMatches() {
        XCTAssertTrue(NumberMatcher.matches("+49 30 1234", "030 1234"))
        XCTAssertFalse(NumberMatcher.matches("030 1234", "030 1235"))
    }
    func testIndexFindsNameAcrossFormats() {
        let c = Contact(id: "1", name: "Erika", numbers: [PhoneNumber(number: "030 1234", type: "home")])
        let index = PhoneBookIndex(contacts: [c])
        XCTAssertEqual(index.name(for: "+49301234"), "Erika")
        XCTAssertNil(index.name(for: "0301235"))
    }
}
