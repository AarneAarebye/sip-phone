// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import Foundation
import PhoneCore

public enum CallListParser {
    public static func parse(_ data: Data, timeZone: TimeZone = .current) throws -> [CallRecord] {
        let delegate = Delegate(timeZone: timeZone)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? FritzError.malformedXML }
        return delegate.records
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var records: [CallRecord] = []
        private var fields: [String: String] = [:]
        private var text = ""
        private var inCall = false
        private let formatter: DateFormatter

        init(timeZone: TimeZone) {
            formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "dd.MM.yy HH:mm"
        }

        func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if el == "Call" { inCall = true; fields = [:] }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if el == "Call" { inCall = false; if let r = build() { records.append(r) } }
            else if inCall { fields[el] = t }
        }

        private func build() -> CallRecord? {
            guard let code = fields["Type"].flatMap(Int.init) else { return nil }
            let type: CallRecordType
            let remote: String?
            let own: String?
            switch code {
            case 1, 9: type = .incoming; remote = fields["Caller"]; own = fields["CalledNumber"] ?? fields["Called"]
            case 2: type = .missed; remote = fields["Caller"]; own = fields["CalledNumber"] ?? fields["Called"]
            case 10: type = .rejected; remote = fields["Caller"]; own = fields["CalledNumber"] ?? fields["Called"]
            case 3, 11: type = .outgoing; remote = fields["Called"]; own = fields["Caller"]
            default: return nil
            }
            guard let date = fields["Date"].flatMap(formatter.date(from:)) else { return nil }
            let parts = (fields["Duration"] ?? "0:00").split(separator: ":").compactMap { Int($0) }
            let duration = parts.count == 2 ? TimeInterval(parts[0] * 3600 + parts[1] * 60) : 0
            let name = fields["Name"].flatMap { $0.isEmpty ? nil : $0 }
            return CallRecord(id: Int(fields["Id"] ?? "") ?? records.count, type: type,
                              remoteNumber: remote ?? "", name: name, date: date, duration: duration,
                              ownNumber: own.flatMap { $0.isEmpty ? nil : $0 })
        }
    }
}
