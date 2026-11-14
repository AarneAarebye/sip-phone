// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import Foundation

/// Quick presets of the log's date filter.
public enum CallLogRangePreset: CaseIterable, Sendable {
    case all, today, last7Days, last30Days

    /// (from, to) for the preset; `to` is open (nil) for all presets, `from` is nil for `.all`.
    public func range(now: Date = Date(), calendar: Calendar = .current) -> (from: Date?, to: Date?) {
        let startOfToday = calendar.startOfDay(for: now)
        switch self {
        case .all: return (nil, nil)
        case .today: return (startOfToday, nil)
        case .last7Days: return (calendar.date(byAdding: .day, value: -6, to: startOfToday), nil)
        case .last30Days: return (calendar.date(byAdding: .day, value: -29, to: startOfToday), nil)
        }
    }
}

public enum CallLogFilter {
    private static func digits(_ s: String) -> String { s.filter { ("0"..."9").contains($0) } }

    /// Empty query matches everything. Otherwise: case-insensitive name substring, or a number match.
    /// Number match is digits-normalised: "+49 30 123" finds "030123" (via NumberMatcher.normalize), and the plain digit
    /// strings are compared as substrings too. A query without digits never matches a number.
    public static func matches(_ r: CallRecord, query: String, countryCode: String = "49", areaCode: String? = nil) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        if let name = r.name, name.localizedCaseInsensitiveContains(q) { return true }
        let qd = digits(q)
        if qd.isEmpty { return false }
        if digits(r.remoteNumber).contains(qd) { return true }
        let nq = NumberMatcher.normalize(q, countryCode: countryCode, areaCode: areaCode)
        let nr = NumberMatcher.normalize(r.remoteNumber, countryCode: countryCode, areaCode: areaCode)
        return !nq.isEmpty && nr.contains(nq)
    }

    /// Both date bounds are inclusive and optional.
    public static func filter(_ records: [CallRecord], query: String, from: Date?, to: Date?,
                              countryCode: String = "49", areaCode: String? = nil) -> [CallRecord] {
        records.filter { r in
            (from.map { r.date >= $0 } ?? true) && (to.map { r.date <= $0 } ?? true)
                && matches(r, query: query, countryCode: countryCode, areaCode: areaCode)
        }
    }
}

public enum CallDuration {
    /// "3:42" under an hour, "1:02:05" from an hour up; nil for zero or negative (missed, rejected, unknown).
    public static func format(_ seconds: TimeInterval) -> String? {
        let t = Int(seconds.rounded())
        guard t > 0 else { return nil }
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
    /// Always h:mm:ss, for the CSV.
    public static func formatFull(_ seconds: TimeInterval) -> String {
        let t = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }
}

public enum CallLogCSV {
    public static let header = ["Date", "Type", "Name", "Number", "Own number", "Duration (s)", "Duration (h:mm:ss)", "Phone book"]

    /// One cell: formula-injection guard (leading = + - @ tab CR gets a single quote), then RFC 4180 quoting.
    public static func escape(_ value: String) -> String {
        var v = value
        if let f = v.first, "=+-@\t\r".contains(f) { v = "'" + v }
        if v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            v = "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }

    public static func typeName(_ t: CallRecordType) -> String {
        switch t { case .incoming: "incoming"; case .missed: "missed"; case .outgoing: "outgoing"; case .rejected: "rejected" }
    }

    /// Phone book name per call id, by number (NumberMatcher-normalised); the first contact wins.
    public static func phoneBooks(for records: [CallRecord], contacts: [Contact],
                                  countryCode: String = "49", areaCode: String? = nil) -> [Int: String] {
        var byNumber: [String: String] = [:]
        for c in contacts {
            guard let book = c.phoneBook, !book.isEmpty else { continue }
            for n in c.numbers {
                let k = NumberMatcher.normalize(n.number, countryCode: countryCode, areaCode: areaCode)
                if !k.isEmpty, byNumber[k] == nil { byNumber[k] = book }
            }
        }
        var out: [Int: String] = [:]
        for r in records {
            let k = NumberMatcher.normalize(r.remoteNumber, countryCode: countryCode, areaCode: areaCode)
            if let b = byNumber[k] { out[r.id] = b }
        }
        return out
    }

    /// CRLF-separated CSV with header. `phoneBook` maps CallRecord.id to a book name.
    public static func build(_ records: [CallRecord], phoneBook: [Int: String] = [:],
                             timeZone: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        var lines = [header.map(escape).joined(separator: ",")]
        for r in records {
            let cells = [f.string(from: r.date), typeName(r.type), r.name ?? "", r.remoteNumber, r.ownNumber ?? "",
                         String(Int(r.duration.rounded())), CallDuration.formatFull(r.duration), phoneBook[r.id] ?? ""]
            lines.append(cells.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    public static func defaultFileName(now: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "sip-phone-calls-%04d-%02d-%02d.csv", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
