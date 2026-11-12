// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import XCTest
@testable import PhoneCore

private func contact(_ id: String, _ name: String, num: String = "030 1", book: String?, bookID: String? = nil) -> Contact {
    Contact(id: id, name: name, numbers: [PhoneNumber(number: num, type: "home")], phoneBook: book, phoneBookID: bookID)
}

final class PhoneBookSelectionTests: XCTestCase {
    private let sample = [
        contact("0-1", "Anna", book: "Telefonbuch (0)", bookID: "0"),
        contact("3-1", "Bob", book: "Work", bookID: "3"),
        contact("0-2", "Cy", book: "Telefonbuch (0)", bookID: "0"),
        contact("7-1", "Dee", book: nil, bookID: "7"),
    ]

    func testSummariesOrderCountsAndFallbackName() {
        let s = PhoneBooks.summaries(from: sample)
        XCTAssertEqual(s.map(\.id), ["0", "3", "7"])
        XCTAssertEqual(s.map(\.contactCount), [2, 1, 1])
        XCTAssertEqual(s.map(\.name), ["Telefonbuch (0)", "Work", "Phone book 7"])
    }
    func testSummariesKeepDuplicateNamesAsSeparateBooks() {
        let s = PhoneBooks.summaries(from: [contact("0-1", "A", book: "Same", bookID: "0"), contact("1-1", "B", book: "Same", bookID: "1")])
        XCTAssertEqual(s.count, 2)
    }
    func testContactsWithoutBookIDBelongToNoBook() {
        XCTAssertTrue(PhoneBooks.summaries(from: [contact("x", "A", book: nil)]).isEmpty)
    }
    func testVisibleFiltering() {
        let all = sample + [contact("loose", "Loose", book: nil)]
        XCTAssertEqual(PhoneBooks.visible(all, disabled: []).count, 5)
        XCTAssertEqual(PhoneBooks.visible(all, disabled: ["0"]).map(\.name), ["Bob", "Dee", "Loose"])
        XCTAssertEqual(PhoneBooks.visible(all, disabled: ["0", "3", "7"]).map(\.name), ["Loose"])
    }
    func testPickerCombinesWithSearch() {
        XCTAssertEqual(PhoneBooks.filter(sample, bookID: nil, query: "").count, 4)
        XCTAssertEqual(PhoneBooks.filter(sample, bookID: "0", query: "").map(\.name), ["Anna", "Cy"])
        XCTAssertEqual(PhoneBooks.filter(sample, bookID: "0", query: "cy").map(\.name), ["Cy"])
        XCTAssertEqual(PhoneBooks.filter(sample, bookID: "3", query: "anna").count, 0)
        XCTAssertEqual(PhoneBooks.filter(sample, bookID: nil, query: "work").map(\.name), ["Bob"])
    }
    func testOldCacheDecodesWithFallbackBookID() throws {
        let json = #"[{"id":"4-12","name":"Old","numbers":[]},{"id":"plain","name":"P","numbers":[]},{"id":"2-5","name":"N","numbers":[],"phoneBook":"X","phoneBookID":"9"}]"#
        let c = try JSONDecoder().decode([Contact].self, from: Data(json.utf8))
        XCTAssertNil(c[0].phoneBookID)
        XCTAssertEqual(c[0].bookID, "4")
        XCTAssertNil(c[1].bookID)
        XCTAssertEqual(c[2].bookID, "9")
    }
    func testDisabledPhoneBooksDecoding() throws {
        XCTAssertEqual(AppSettings().disabledPhoneBooks, [])
        let missing = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"sipUser":"1"}"#.utf8))
        XCTAssertEqual(missing.disabledPhoneBooks, [])
        let bad = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"sipUser":"1","disabledPhoneBooks":"x"}"#.utf8))
        XCTAssertEqual(bad.disabledPhoneBooks, [])
        var s = AppSettings(); s.disabledPhoneBooks = ["3"]
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.disabledPhoneBooks, ["3"])
    }
}

@MainActor final class PhoneBookCoreTests: XCTestCase {
    private func rig() async -> Rig {
        let r = makeRig(reach: [true])
        r.book.contacts = [
            contact("0-1", "Erika", num: "030 1234", book: "Main", bookID: "0"),
            contact("2-1", "Work Guy", num: "030 9999", book: "Work", bookID: "2"),
        ]
        await r.core.start()
        return r
    }
    private func ring(_ r: Rig, _ n: String) -> String? {
        r.core.handle(.incomingCall(id: 1, remote: n, called: nil))
        return r.core.activeCall?.displayName
    }
    func testDisablingBookHidesContactsAndStopsLookup() async {
        let r = await rig()
        XCTAssertEqual(r.core.phoneBooks.map(\.id), ["0", "2"])
        var s = r.core.settings; s.disabledPhoneBooks = ["2"]
        r.core.updateSettings(s)
        XCTAssertEqual(r.core.visibleContacts.map(\.name), ["Erika"])
        XCTAssertEqual(r.core.contacts.count, 2)
        XCTAssertEqual(r.core.phoneBooks.count, 2)
        XCTAssertNil(ring(r, "0309999"))
    }
    func testReenablingRestores() async {
        let r = await rig()
        var s = r.core.settings; s.disabledPhoneBooks = ["2"]
        r.core.updateSettings(s)
        s.disabledPhoneBooks = []
        r.core.updateSettings(s)
        XCTAssertEqual(r.core.visibleContacts.count, 2)
        XCTAssertEqual(ring(r, "0309999"), "Work Guy")
    }
    func testNewBookDefaultsToEnabledAndRefreshKeepsDisabledSet() async {
        let r = await rig()
        var s = r.core.settings; s.disabledPhoneBooks = ["2"]
        r.core.updateSettings(s)
        r.book.contacts.append(contact("5-1", "New", num: "030 5555", book: "Fresh", bookID: "5"))
        await r.core.refreshPhoneBook()
        XCTAssertEqual(r.core.settings.disabledPhoneBooks, ["2"])
        XCTAssertEqual(r.core.visibleContacts.map(\.name), ["Erika", "New"])
        XCTAssertEqual(ring(r, "0305555"), "New")
    }
}
