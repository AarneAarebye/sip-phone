// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import XCTest
@testable import PhoneCore

private func rec(_ id: Int, _ number: String, _ type: CallRecordType = .incoming, name: String? = nil,
                 at t: TimeInterval = 0, dur: TimeInterval = 0, own: String? = nil) -> CallRecord {
    CallRecord(id: id, type: type, remoteNumber: number, name: name, date: Date(timeIntervalSince1970: t), duration: dur, ownNumber: own)
}

private func utcCalendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

final class CallLogToolsTests: XCTestCase {
    func testTextFilterNumberVariants() {
        let r = rec(1, "030 123456")
        XCTAssertTrue(CallLogFilter.matches(r, query: "+49 30 123"))
        XCTAssertTrue(CallLogFilter.matches(r, query: "030123"))
        XCTAssertTrue(CallLogFilter.matches(r, query: "0049 30 1234"))
        XCTAssertTrue(CallLogFilter.matches(r, query: "123456"))
        XCTAssertFalse(CallLogFilter.matches(r, query: "0171"))
        XCTAssertFalse(CallLogFilter.matches(r, query: "xyz"))
        XCTAssertTrue(CallLogFilter.matches(r, query: "  "))
    }
    func testTextFilterName() {
        let r = rec(1, "1", name: "Erika Mustermann")
        XCTAssertTrue(CallLogFilter.matches(r, query: "muster"))
        XCTAssertFalse(CallLogFilter.matches(r, query: "max"))
    }
    func testDateRangeInclusiveAndOpen() {
        let rs = [rec(1, "1", at: 100), rec(2, "1", at: 200), rec(3, "1", at: 300)]
        func d(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }
        XCTAssertEqual(CallLogFilter.filter(rs, query: "", from: d(200), to: nil).map(\.id), [2, 3])
        XCTAssertEqual(CallLogFilter.filter(rs, query: "", from: nil, to: d(200)).map(\.id), [1, 2])
        XCTAssertEqual(CallLogFilter.filter(rs, query: "", from: d(150), to: d(250)).map(\.id), [2])
        XCTAssertEqual(CallLogFilter.filter(rs, query: "", from: nil, to: nil).count, 3)
    }
    func testPresets() {
        let cal = utcCalendar()
        let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13 UTC
        let midnight: TimeInterval = 1_699_920_000
        XCTAssertEqual(CallLogRangePreset.today.range(now: now, calendar: cal).from, Date(timeIntervalSince1970: midnight))
        XCTAssertEqual(CallLogRangePreset.last7Days.range(now: now, calendar: cal).from, Date(timeIntervalSince1970: midnight - 6 * 86400))
        XCTAssertEqual(CallLogRangePreset.last30Days.range(now: now, calendar: cal).from, Date(timeIntervalSince1970: midnight - 29 * 86400))
        XCTAssertNil(CallLogRangePreset.all.range(now: now, calendar: cal).from)
    }
    func testDurationFormat() {
        XCTAssertNil(CallDuration.format(0))
        XCTAssertEqual(CallDuration.format(222), "3:42")
        XCTAssertEqual(CallDuration.format(3725), "1:02:05")
        XCTAssertEqual(CallDuration.format(59), "0:59")
        XCTAssertEqual(CallDuration.formatFull(222), "0:03:42")
        XCTAssertEqual(CallDuration.formatFull(3725), "1:02:05")
    }
    func testCSVEscaping() {
        XCTAssertEqual(CallLogCSV.escape("plain"), "plain")
        XCTAssertEqual(CallLogCSV.escape("a,b"), "\"a,b\"")
        XCTAssertEqual(CallLogCSV.escape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(CallLogCSV.escape("line\nbreak"), "\"line\nbreak\"")
    }
    func testCSVFormulaGuard() {
        for p in ["=1+1", "+49 30", "-1", "@SUM(A1)"] { XCTAssertEqual(CallLogCSV.escape(p), "'" + p) }
        XCTAssertEqual(CallLogCSV.escape("=a,b"), "\"'=a,b\"")
    }
    func testCSVBuild() {
        let rs = [rec(1, "+4930123", .outgoing, name: "Doe, Jane", at: 1_700_000_000, dur: 3725, own: "9876"),
                  rec(2, "0171", .missed, name: "=evil()", at: 1_700_000_060)]
        let csv = CallLogCSV.build(rs, phoneBook: [1: "Work"], timeZone: TimeZone(identifier: "UTC")!)
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertEqual(lines[0], "Date,Type,Name,Number,Own number,Duration (s),Duration (h:mm:ss),Phone book")
        XCTAssertEqual(lines[1], "2023-11-14T22:13:20Z,outgoing,\"Doe, Jane\",'+4930123,9876,3725,1:02:05,Work")
        XCTAssertEqual(lines[2], "2023-11-14T22:14:20Z,missed,'=evil(),0171,,0,0:00:00,")
        XCTAssertEqual(lines[3], "")
    }
    func testPhoneBookLookup() {
        let c = Contact(id: "0-1", name: "A", numbers: [PhoneNumber(number: "+49 30 123", type: "home")], phoneBook: "Work", phoneBookID: "0")
        XCTAssertEqual(CallLogCSV.phoneBooks(for: [rec(1, "030123"), rec(2, "999")], contacts: [c]), [1: "Work"])
    }
    func testFileName() {
        XCTAssertEqual(CallLogCSV.defaultFileName(now: Date(timeIntervalSince1970: 1_700_000_000), calendar: utcCalendar()),
                       "sip-phone-calls-2023-11-14.csv")
    }
}
