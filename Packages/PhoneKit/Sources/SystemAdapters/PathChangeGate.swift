// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 SIP Phone contributors

import Foundation

/// Pure decision logic for network-path changes: ignore the initial callback and repeats of the same
/// signature; after a real change the caller waits `debounce` and then re-checks `shouldReconnect`.
public struct PathChangeGate: Equatable {
    public static let debounce: Duration = .seconds(3)
    private var last: String?
    public init() {}

    /// Returns true when the change should start (or restart) the debounce timer.
    public mutating func observe(_ signature: String) -> Bool {
        defer { last = signature }
        guard let last else { return false }   // initial callback
        return last != signature
    }

    /// Evaluated after the debounce: an in-flight VPN connect is itself changing the path, so leave it alone.
    public static func shouldReconnect(isConnectingVPN: Bool) -> Bool { !isConnectingVPN }

    public static func signature(interfaceNames: [String], satisfied: Bool) -> String {
        interfaceNames.joined(separator: ",") + (satisfied ? "+" : "-")
    }
}

public enum PowerSourceInterpreter {
    /// `type` is the value of IOPSGetProvidingPowerSourceType ("AC Power", "Battery Power", "UPS Power").
    public static func isOnAC(providingType type: String?, acValue: String) -> Bool { type == acValue }
}
