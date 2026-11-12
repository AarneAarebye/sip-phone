// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import Foundation

/// Turns the way a call ended into user-facing wording. Only `isError` results are shown as errors.
public enum CallEndDescription {
    public static func describe(code: Int, reason: String, isIncoming: Bool, wasConnected: Bool, endedLocally: Bool) -> (text: String, isError: Bool) {
        if wasConnected {
            return (endedLocally ? "Call ended" : "Call ended by the other party", false)
        }
        if isIncoming {
            return (endedLocally ? "Call declined" : "Missed call", false)
        }
        if endedLocally { return ("Call cancelled", false) }
        switch code {
        case 603: return ("Declined by the other party", false)
        case 486, 600: return ("Busy", false)
        case 404, 480, 484, 410, 604: return ("Not available", false)
        case 408, 504: return ("No answer", false)
        default:
            let r = reason.trimmingCharacters(in: .whitespaces)
            return (r.isEmpty ? "Call failed: \(code)" : "Call failed: \(code) \(r)", true)
        }
    }
}
