// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import XCTest
@testable import PhoneCore

final class ContactFilterTests: XCTestCase {
    private let c = Contact(id: "1-5", name: "Erika Mustermann", numbers: [PhoneNumber(number: "030 1234567", type: "home")], phoneBook: "Familie")

    func testMatchesNameNumberAndBook() {
        XCTAssertTrue(ContactFilter.matches(c, "erika"))
        XCTAssertTrue(ContactFilter.matches(c, "1234567"))
        XCTAssertTrue(ContactFilter.matches(c, "FAMILIE"))
        XCTAssertTrue(ContactFilter.matches(c, ""))
        XCTAssertFalse(ContactFilter.matches(c, "Arbeit"))
    }

    func testNilBookDoesNotMatch() {
        XCTAssertFalse(ContactFilter.matches(Contact(id: "1", name: "A", numbers: []), "Familie"))
    }

    func testDecodesOldCacheJSONWithoutPhoneBook() throws {
        let old = Data(#"[{"id":"0-11","name":"Erika","numbers":[{"number":"030","type":"home"}]}]"#.utf8)
        let decoded = try JSONDecoder().decode([Contact].self, from: old)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].phoneBook)
        XCTAssertEqual(decoded[0].id, "0-11")
    }

    func testRoundTripKeepsPhoneBook() throws {
        let back = try JSONDecoder().decode([Contact].self, from: JSONEncoder().encode([c]))
        XCTAssertEqual(back, [c])
    }
}
