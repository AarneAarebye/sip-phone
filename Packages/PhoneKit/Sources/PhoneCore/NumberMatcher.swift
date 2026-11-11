import Foundation

public enum NumberMatcher {
    private static func digits(_ s: String) -> String { s.filter { ("0"..."9").contains($0) } }

    /// Digits-only form with country code, e.g. "+49 30 1234" and "030 1234" -> "49301234".
    public static func normalize(_ raw: String, countryCode: String = "49", areaCode: String? = nil) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let d = digits(trimmed)
        if d.isEmpty { return "" }
        if trimmed.hasPrefix("+") { return d }
        if d.hasPrefix("00") { return String(d.dropFirst(2)) }
        if d.hasPrefix("0") { return countryCode + d.dropFirst() }
        if let area = areaCode.map(digits), !area.isEmpty {
            let a = area.hasPrefix("0") ? String(area.dropFirst()) : area
            return countryCode + a + d
        }
        return d
    }

    public static func matches(_ a: String, _ b: String, countryCode: String = "49", areaCode: String? = nil) -> Bool {
        let na = normalize(a, countryCode: countryCode, areaCode: areaCode)
        return !na.isEmpty && na == normalize(b, countryCode: countryCode, areaCode: areaCode)
    }
}

public struct PhoneBookIndex: Sendable {
    private let names: [String: String]
    private let countryCode: String
    private let areaCode: String?

    public init(contacts: [Contact], countryCode: String = "49", areaCode: String? = nil) {
        var map: [String: String] = [:]
        for c in contacts {
            for n in c.numbers {
                let key = NumberMatcher.normalize(n.number, countryCode: countryCode, areaCode: areaCode)
                if !key.isEmpty, map[key] == nil { map[key] = c.name }
            }
        }
        self.names = map; self.countryCode = countryCode; self.areaCode = areaCode
    }

    public func name(for number: String) -> String? {
        let key = NumberMatcher.normalize(number, countryCode: countryCode, areaCode: areaCode)
        return key.isEmpty ? nil : names[key]
    }
}
