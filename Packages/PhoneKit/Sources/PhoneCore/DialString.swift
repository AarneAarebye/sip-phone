// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import Foundation

/// Shared clean-up of user- or phone-book-supplied numbers, used for dialling and for matching.
public enum DialString {
    /// Formatting characters that carry no meaning in a number: space, - / ( ) . and no-break space.
    static let formatting: Set<Character> = [" ", "-", "/", "(", ")", ".", "\u{00A0}"]

    /// Trims surrounding whitespace/newlines, drops the "(0)" trunk prefix after a "+cc" prefix
    /// ("+49 (0)30 1234" -> "+49301234") and strips formatting characters. Anything else is kept as is.
    public static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: #"^\+[0-9]{1,4}[ \x{00A0}]*\(0\)"#, options: .regularExpression) {
            s.replaceSubrange(r, with: s[r].prefix { $0 != "(" }.filter { !formatting.contains($0) })
        }
        return String(s.filter { !formatting.contains($0) })
    }

    /// The cleaned number if it is safe to put into a SIP URI (`^\+?[0-9*#]+$`), else nil.
    public static func dialable(_ raw: String) -> String? {
        let s = clean(raw)
        return isDialable(s) ? s : nil
    }

    public static func isDialable(_ s: String) -> Bool {
        s.range(of: #"^\+?[0-9*#]+$"#, options: .regularExpression) != nil
    }
}
