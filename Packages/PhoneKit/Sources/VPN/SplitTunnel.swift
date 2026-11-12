// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import Foundation
import Darwin

/// Which traffic the tunnel carries, chosen in Settings.
public struct TunnelRouting: Equatable, Sendable {
    /// true: only the home network goes through the VPN; false: the config's own AllowedIPs (usually everything).
    public var splitTunnel: Bool
    /// Home network override as a CIDR; nil or empty = derived from the config's [Interface] Address.
    public var homeNetwork: String?
    public init(splitTunnel: Bool, homeNetwork: String? = nil) { self.splitTunnel = splitTunnel; self.homeNetwork = homeNetwork }
    public static let full = TunnelRouting(splitTunnel: false)
}

/// Rewrites a wg-quick config for a split tunnel: every [Peer] AllowedIPs becomes the home network, so only
/// traffic for the home LAN uses the VPN and the Mac's default route stays on the physical interface.
///
/// Everything else (keys, endpoint, keepalive, pre-shared key, DNS, comments) is kept byte for byte. Error
/// messages never contain values from the config; the rewritten text must never be logged.
public enum SplitTunnelConfig {
    /// The prefix used for the home network derived from an IPv4 / IPv6 interface address.
    static let derivedIPv4Prefix = 24
    static let derivedIPv6Prefix = 64

    /// Returns the config with each [Peer]'s AllowedIPs replaced by one `AllowedIPs = <home network>` line.
    ///
    /// Home network: `override` (a CIDR, normalized) when given, else the first IPv4 `Address` widened to
    /// its /24 (192.168.65.204/32 -> 192.168.65.0/24). IPv6 is dropped from AllowedIPs unless the interface
    /// has IPv6 addresses only; then the first one's /64 is used.
    public static func rewrite(_ text: String, homeNetwork override: String?) throws -> String {
        let home: String
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let cidr = normalizedCIDR(override) else {
                throw VPNError.invalidConfig("home network is not a valid CIDR (e.g. 192.168.65.0/24)")
            }
            home = cidr
        } else {
            guard let derived = homeNetwork(fromAddresses: interfaceAddresses(text)) else {
                throw VPNError.invalidConfig("[Interface] Address missing or not an IP address")
            }
            home = derived
        }

        var out: [String] = []
        var inPeer = false
        var peers = 0
        var wroteAllowed = false
        var lastContent = -1   // index in `out` of the current peer section's last non-empty line

        func closePeer() {
            if inPeer && !wroteAllowed { out.insert("AllowedIPs = \(home)", at: lastContent + 1) }
        }
        // components(separatedBy:) splits CRLF too ("\r\n" is one Character for String.split); the "\r" is kept.
        for line in text.components(separatedBy: "\n") {
            let cr = line.hasSuffix("\r") ? "\r" : ""
            let content = strip(line)
            if content.hasPrefix("[") {
                closePeer()
                inPeer = content.lowercased() == "[peer]"
                if inPeer { peers += 1; wroteAllowed = false }
                out.append(line); lastContent = out.count - 1
                continue
            }
            if inPeer, key(of: content) == "allowedips" {
                if !wroteAllowed {
                    out.append("AllowedIPs = \(home)\(cr)"); wroteAllowed = true; lastContent = out.count - 1
                }
                continue   // further AllowedIPs lines of this peer are dropped
            }
            out.append(line)
            if !content.isEmpty { lastContent = out.count - 1 }
        }
        closePeer()
        guard peers > 0 else { throw VPNError.invalidConfig("no [Peer] section") }
        return out.joined(separator: "\n")
    }

    /// "192.168.65.7/24" -> "192.168.65.0/24" (host bits cleared). nil unless it is an IPv4 CIDR with a
    /// prefix of 1...32 or an IPv6 CIDR with 1...128 (a /0 would send everything through the VPN).
    public static func normalizedCIDR(_ text: String) -> String? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), parts[1].allSatisfy(\.isNumber) else { return nil }
        guard let ip = IP(String(parts[0])), prefix >= 1, prefix <= ip.bits else { return nil }
        return ip.network(prefix: prefix)
    }

    // MARK: Helpers

    static func homeNetwork(fromAddresses addresses: [String]) -> String? {
        let ips = addresses.compactMap { IP(String($0.split(separator: "/").first ?? "")) }
        if let v4 = ips.first(where: { $0.bits == 32 }) { return v4.network(prefix: derivedIPv4Prefix) }
        if let v6 = ips.first { return v6.network(prefix: derivedIPv6Prefix) }
        return nil
    }

    /// All comma-separated entries of every `Address` line in [Interface].
    static func interfaceAddresses(_ text: String) -> [String] {
        var inInterface = false
        var result: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let content = strip(String(raw))
            if content.hasPrefix("[") { inInterface = content.lowercased() == "[interface]"; continue }
            guard inInterface, key(of: content) == "address", let eq = content.firstIndex(of: "=") else { continue }
            result += content[content.index(after: eq)...].split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return result
    }

    private static func strip(_ line: String) -> String {
        (line.firstIndex(of: "#").map { String(line[..<$0]) } ?? line).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func key(of content: String) -> String? {
        content.firstIndex(of: "=").map { content[..<$0].trimmingCharacters(in: .whitespaces).lowercased() }
    }

    /// An IPv4 or IPv6 address as raw bytes.
    private struct IP {
        var bytes: [UInt8]
        var bits: Int { bytes.count * 8 }

        init?(_ s: String) {
            let s = s.trimmingCharacters(in: .whitespaces)
            var v4 = in_addr(), v6 = in6_addr()
            if s.contains(":") {
                guard inet_pton(AF_INET6, s, &v6) == 1 else { return nil }
                bytes = withUnsafeBytes(of: &v6) { Array($0) }
            } else {
                // inet_pton(AF_INET) accepts only the dotted-quad form.
                guard inet_pton(AF_INET, s, &v4) == 1 else { return nil }
                bytes = withUnsafeBytes(of: &v4) { Array($0) }
            }
        }

        func network(prefix: Int) -> String {
            var masked = bytes
            for i in masked.indices {
                let keep = max(0, min(8, prefix - i * 8))
                masked[i] &= keep == 0 ? 0 : UInt8(truncatingIfNeeded: 0xFF << (8 - keep))
            }
            let family = bytes.count == 4 ? AF_INET : AF_INET6
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            _ = masked.withUnsafeBytes { inet_ntop(family, $0.baseAddress, &buffer, socklen_t(buffer.count)) }
            return String(cString: buffer) + "/\(prefix)"
        }
    }
}
