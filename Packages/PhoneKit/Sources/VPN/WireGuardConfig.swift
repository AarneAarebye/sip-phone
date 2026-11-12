// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import Foundation

/// Light structural check of a wg-quick config, done in the app before anything touches the system.
/// The full parse happens in the tunnel provider (WireGuardKit types). Error messages never include
/// values from the config, so they are safe to show and log.
public enum WireGuardConfigCheck {
    /// Returns the first peer's `Endpoint` (host:port, used as the VPN's display server address).
    public static func validate(_ text: String) throws -> String {
        var sections: [(name: String, keys: [String: String])] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = (raw.firstIndex(of: "#").map { raw[..<$0] } ?? raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                sections.append((line.lowercased(), [:]))
            } else if let eq = line.firstIndex(of: "="), !sections.isEmpty {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                sections[sections.count - 1].keys[key] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            } else {
                throw VPNError.invalidConfig("unexpected line outside [Interface]/[Peer]")
            }
        }
        let interfaces = sections.filter { $0.name == "[interface]" }
        guard interfaces.count == 1, let iface = interfaces.first?.keys else {
            throw VPNError.invalidConfig("needs exactly one [Interface] section")
        }
        guard isKey(iface["privatekey"]) else { throw VPNError.invalidConfig("[Interface] PrivateKey missing or not a WireGuard key") }
        guard iface["address"]?.isEmpty == false else { throw VPNError.invalidConfig("[Interface] Address missing") }
        let peers = sections.filter { $0.name == "[peer]" }.map(\.keys)
        guard !peers.isEmpty else { throw VPNError.invalidConfig("no [Peer] section") }
        guard peers.allSatisfy({ isKey($0["publickey"]) }) else { throw VPNError.invalidConfig("[Peer] PublicKey missing or not a WireGuard key") }
        guard let endpoint = peers.compactMap({ $0["endpoint"] }).first(where: { $0.contains(":") }) else {
            throw VPNError.invalidConfig("[Peer] Endpoint (host:port) missing")
        }
        return endpoint
    }

    private static func isKey(_ value: String?) -> Bool {
        guard let value, let data = Data(base64Encoded: value) else { return false }
        return data.count == 32
    }
}

/// The one place where the wg-quick config crosses from the app to the system-extension tunnel.
///
/// It travels in the `options` of `NETunnelProviderSession.startTunnel(options:)`: kept in memory only,
/// never written to the VPN preferences (`providerConfiguration`/`passwordReference`). A system extension
/// runs as root outside the user session and cannot read the user's (data protection) keychain, so the
/// app reads the config from its own keychain and hands it over at every start. Consequence: the tunnel
/// can only be started by this app (a start from System Settings has no options and fails cleanly).
public enum TunnelConfigHandoff {
    static let optionKey = "wgQuickConfig"
    public static func startOptions(config: String) -> [String: NSObject] { [optionKey: config as NSString] }
    public static func config(fromStartOptions options: [String: NSObject]?) -> String? {
        (options?[optionKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
