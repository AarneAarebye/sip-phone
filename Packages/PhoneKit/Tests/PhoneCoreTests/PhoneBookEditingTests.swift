// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import XCTest
@testable import PhoneCore

private final class FakeEditing: PhoneBookEditing, @unchecked Sendable {
    struct Failure: Error, LocalizedError { var errorDescription: String? { "boom" } }
    var calls: [String] = []
    var sets: [(book: String, id: String, data: String)] = []
    var stored = "<contact><category>1</category><person><realName>Old</realName></person>"
        + "<telephony nid=\"1\"><number type=\"home\" id=\"0\">111</number></telephony>"
        + "<services><email classifier=\"private\">a@b.c</email></services><uniqueid>7</uniqueid></contact>"
    var failSet = false, failDelete = false
    func entryData(bookID: String, entryID: String) async throws -> String { calls.append("get \(bookID) \(entryID)"); return stored }
    func setEntry(bookID: String, entryID: String, data: String) async throws -> String {
        calls.append("set \(bookID) \(entryID)")
        if failSet { throw Failure() }
        sets.append((bookID, entryID, data)); return "99"
    }
    func deleteEntry(bookID: String, entryID: String) async throws {
        calls.append("delete \(bookID) \(entryID)")
        if failDelete { throw Failure() }
    }
}

final class PhoneBookEditingTests: XCTestCase {
    private let draft = ContactDraft(name: "Erika <&> \"Muster\"", numbers: [PhoneNumber(number: "030 123", type: "work"), PhoneNumber(number: " ", type: "home")])

    func testBuildEscapesAndSkipsEmptyNumbers() throws {
        let xml = PhoneBookEntryXML.build(draft.cleaned)
        XCTAssertTrue(xml.contains("<realName>Erika &lt;&amp;&gt; &quot;Muster&quot;</realName>"))
        XCTAssertTrue(xml.contains("<number type=\"work\" prio=\"1\" id=\"0\">030 123</number>"))
        XCTAssertEqual(xml.components(separatedBy: "<number ").count, 2)
        XCTAssertNoThrow(try XMLDocument(xmlString: xml, options: []))
    }

    func testEscapeDropsControlCharacters() {
        XCTAssertEqual(PhoneBookEntryXML.escape("a\u{1}b'c"), "ab&apos;c")
    }

    func testValidation() {
        XCTAssertNotNil(ContactDraft(name: " ", numbers: [PhoneNumber(number: "1", type: "home")]).validationError)
        XCTAssertNotNil(ContactDraft(name: "A", numbers: [PhoneNumber(number: "  ", type: "home")]).validationError)
        XCTAssertNotNil(ContactDraft(name: "A", numbers: [PhoneNumber(number: "12<3", type: "home")]).validationError)
        XCTAssertNotNil(ContactDraft(name: "A", numbers: [PhoneNumber(number: "()", type: "home")]).validationError)
        XCTAssertNil(ContactDraft(name: "A", numbers: [PhoneNumber(number: "+49 (30) 12-3", type: "other")]).validationError)
    }

    func testUnknownTypeFallsBackToOther() {
        let c = Contact(id: "0-1", name: "A", numbers: [PhoneNumber(number: "1", type: "weird")])
        XCTAssertEqual(ContactDraft(c).numbers.first?.type, "other")
        XCTAssertEqual(PhoneNumberType.from("fax_work"), .faxWork)
    }

    func testMergeKeepsEmailAndIDsReplacesNameAndNumbers() throws {
        let merged = try PhoneBookEntryXML.merge(existing: FakeEditing().stored,
                                                 draft: ContactDraft(name: "New & Co", numbers: [PhoneNumber(number: "222", type: "mobile")]))
        XCTAssertTrue(merged.contains("a@b.c"))
        XCTAssertTrue(merged.contains("<realName>New &amp; Co</realName>"))
        XCTAssertFalse(merged.contains("Old"))
        XCTAssertFalse(merged.contains(">111<"))
        XCTAssertTrue(merged.contains("type=\"mobile\""))
        XCTAssertTrue(merged.contains("<category>1</category>"))
    }

    func testMergeRejectsGarbage() {
        XCTAssertThrowsError(try PhoneBookEntryXML.merge(existing: "not xml", draft: draft.cleaned))
        XCTAssertThrowsError(try PhoneBookEntryXML.forCopy("<other/>"))
    }

    func testForCopyDropsUniqueID() throws {
        let copy = try PhoneBookEntryXML.forCopy(FakeEditing().stored)
        XCTAssertFalse(copy.contains("uniqueid"))
        XCTAssertTrue(copy.contains("a@b.c"))
    }

    func testCreateUsesEmptyEntryID() async throws {
        let f = FakeEditing()
        try await PhoneBookEditor(f).create(bookID: "0", draft: draft)
        XCTAssertEqual(f.calls, ["set 0 "])
    }

    func testCreateRejectsInvalidWithoutCalling() async {
        let f = FakeEditing()
        do { try await PhoneBookEditor(f).create(bookID: "0", draft: ContactDraft(name: "", numbers: [])); XCTFail() }
        catch { XCTAssertEqual(error as? PhoneBookEditError, .invalid("Enter a name.")) }
        XCTAssertTrue(f.calls.isEmpty)
    }

    func testUpdateReadsThenWritesSameID() async throws {
        let f = FakeEditing()
        try await PhoneBookEditor(f).update(bookID: "0", entryID: "7", draft: draft)
        XCTAssertEqual(f.calls, ["get 0 7", "set 0 7"])
        XCTAssertTrue(f.sets[0].data.contains("a@b.c"))
    }

    func testMoveCreatesBeforeDelete() async throws {
        let f = FakeEditing()
        try await PhoneBookEditor(f).transfer(from: "0", entryID: "7", to: "1", mode: .move)
        XCTAssertEqual(f.calls, ["get 0 7", "set 1 ", "delete 0 7"])
    }

    func testCopyDoesNotDelete() async throws {
        let f = FakeEditing()
        try await PhoneBookEditor(f).transfer(from: "0", entryID: "7", to: "1", mode: .copy)
        XCTAssertEqual(f.calls, ["get 0 7", "set 1 "])
    }

    func testFailedCreateNeverDeletes() async {
        let f = FakeEditing(); f.failSet = true
        do { try await PhoneBookEditor(f).transfer(from: "0", entryID: "7", to: "1", mode: .move); XCTFail() } catch {}
        XCTAssertEqual(f.calls, ["get 0 7", "set 1 "])
    }

    func testFailedDeleteAfterCreateReportsCopy() async {
        let f = FakeEditing(); f.failDelete = true
        do { try await PhoneBookEditor(f).transfer(from: "0", entryID: "7", to: "1", mode: .move); XCTFail() }
        catch { XCTAssertEqual(error as? PhoneBookEditError, .copiedButNotRemoved("boom")) }
    }

    func testTransferGuards() async {
        let f = FakeEditing()
        do { try await PhoneBookEditor(f).transfer(from: "0", entryID: "7", to: "0", mode: .copy); XCTFail() } catch {}
        do { try await PhoneBookEditor(f).delete(bookID: "0", entryID: ""); XCTFail() } catch {}
        XCTAssertTrue(f.calls.isEmpty)
    }

    func testTransferTargetsExcludeSourceReadOnlyAndDisabled() {
        let books = [PhoneBookSummary(id: "0", name: "A", contactCount: 1), PhoneBookSummary(id: "1", name: "B", contactCount: 1),
                     PhoneBookSummary(id: "2", name: "C", contactCount: 1, readOnly: true), PhoneBookSummary(id: "3", name: "D", contactCount: 1)]
        let c = Contact(id: "0-7", name: "X", numbers: [], phoneBook: "A", phoneBookID: "0", entryID: "7")
        XCTAssertEqual(TransferTargets.targets(for: c, books: books, disabled: ["3"]).map(\.id), ["1"])
        XCTAssertTrue(TransferTargets.canEdit(c))
        XCTAssertFalse(TransferTargets.canEdit(Contact(id: "0-7", name: "X", numbers: [], phoneBookID: "0", entryID: "7", phoneBookReadOnly: true)))
        XCTAssertFalse(TransferTargets.canEdit(Contact(id: "0-7", name: "X", numbers: [], phoneBookID: "0")))
    }

    func testSummariesCarryReadOnly() {
        let cs = [Contact(id: "0-1", name: "a", numbers: [], phoneBookID: "0"),
                  Contact(id: "1-1", name: "b", numbers: [], phoneBookID: "1", phoneBookReadOnly: true)]
        XCTAssertEqual(PhoneBooks.summaries(from: cs).map(\.readOnly), [false, true])
    }

    func testContactDecodesOldCacheWithoutNewFields() throws {
        let json = #"{"id":"0-1","name":"A","numbers":[]}"#
        let c = try JSONDecoder().decode(Contact.self, from: Data(json.utf8))
        XCTAssertNil(c.entryID); XCTAssertFalse(c.phoneBookReadOnly)
        let again = try JSONDecoder().decode(Contact.self, from: JSONEncoder().encode(Contact(id: "0-1", name: "A", numbers: [], entryID: "1", phoneBookReadOnly: true)))
        XCTAssertEqual(again.entryID, "1"); XCTAssertTrue(again.phoneBookReadOnly)
    }

    func testContactCSVQuotesAndGuardsFormulas() {
        let c = [Contact(id: "0-1", name: "=cmd, \"x\"", numbers: [PhoneNumber(number: "+49 30", type: "home"), PhoneNumber(number: "2", type: "work")], phoneBook: "Tel"),
                 Contact(id: "0-2", name: "Empty", numbers: [], phoneBook: "Tel")]
        let csv = ContactCSV.build(c)
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "Phone book,Name,Type,Number")
        XCTAssertEqual(lines[1], "Tel,\"'=cmd, \"\"x\"\"\",home,'+49 30")
        XCTAssertEqual(lines[2], "Tel,\"'=cmd, \"\"x\"\"\",work,2")
        XCTAssertEqual(lines[3], "Tel,Empty,,")
        XCTAssertTrue(csv.hasSuffix("\r\n"))
    }

    func testBackupFileName() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(ContactCSV.defaultFileName(book: "Tele/fon 1", now: Date(timeIntervalSince1970: 0), calendar: cal),
                       "phonebook-backup-Tele-fon-1-1970-01-01.csv")
    }
}
