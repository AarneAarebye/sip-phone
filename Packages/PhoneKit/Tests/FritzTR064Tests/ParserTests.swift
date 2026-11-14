// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import XCTest
import PhoneCore
@testable import FritzTR064

final class ParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testPhoneBook() throws {
        let contacts = try PhoneBookParser.parse(try fixture("phonebook"))
        XCTAssertEqual(contacts.count, 2)
        XCTAssertEqual(contacts[0].id, "11")
        XCTAssertEqual(contacts[0].name, "Erika Mustermann")
        XCTAssertEqual(contacts[0].numbers, [PhoneNumber(number: "030 1234567", type: "home"),
                                             PhoneNumber(number: "0171 5551234", type: "mobile")])
        XCTAssertEqual(contacts[1].numbers.first?.number, "+49 89 998877")
    }

    func testPhoneBookNameAttribute() throws {
        XCTAssertEqual(try PhoneBookParser.parse(try fixture("phonebook")).map(\.phoneBook), ["Telefonbuch", "Telefonbuch"])
        func parse(_ attr: String) throws -> String? {
            let xml = "<phonebooks><phonebook \(attr)><contact><person><realName>A</realName></person><uniqueid>1</uniqueid></contact></phonebook></phonebooks>"
            return try PhoneBookParser.parse(Data(xml.utf8)).first?.phoneBook
        }
        XCTAssertEqual(try parse(#"name="  Familie  ""#), "Familie")
        XCTAssertNil(try parse(#"name="   ""#))
        XCTAssertNil(try parse(#"owner="0""#))
    }

    func testCallList() throws {
        let tz = TimeZone(identifier: "Europe/Berlin")!
        let calls = try CallListParser.parse(try fixture("calllist"), timeZone: tz)
        XCTAssertEqual(calls.map(\.type), [.incoming, .missed, .outgoing])
        XCTAssertEqual(calls[0].remoteNumber, "030 1234567")   // incoming -> Caller
        XCTAssertEqual(calls[0].name, "Erika Mustermann")
        XCTAssertEqual(calls[0].duration, 12 * 60)
        XCTAssertNil(calls[1].name)
        XCTAssertEqual(calls[2].remoteNumber, "089 998877")    // outgoing -> Called
        XCTAssertEqual(calls[2].duration, 3600 + 5 * 60)
        XCTAssertEqual(calls.map(\.ownNumber), ["9876543", "9876543", "9876543"])   // incoming/missed -> Called, outgoing -> Caller
        XCTAssertEqual(calls[1].duration, 0)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: calls[0].date)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute], [2026, 11, 11, 10, 15])
    }

    func testMalformedXMLThrows() {
        XCTAssertThrowsError(try PhoneBookParser.parse(Data("<a>".utf8)))
    }
}
