// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import Foundation

/// One IPv4 address of a network interface, e.g. ("utun4", "192.168.65.204").
public struct InterfaceAddress: Equatable, Sendable {
    public var name: String
    public var ipv4: String
    public init(name: String, ipv4: String) { self.name = name; self.ipv4 = ipv4 }
}

/// Picks the local address for call audio in `MediaAddressMode.tunnelInterface`.
public enum MediaAddress {
    /// The IPv4 of the VPN tunnel (a `utun` interface): with `homeNetwork` (IPv4 CIDR) set, the first tunnel
    /// address inside it; otherwise the first private tunnel address that is not in the /24 of a non-tunnel
    /// interface (so a tunnel of another VPN that mirrors the local LAN is not taken). nil = no tunnel up.
    public static func tunnelAddress(from interfaces: [InterfaceAddress], homeNetwork: String?) -> String? {
        let tunnels = interfaces.filter { $0.name.hasPrefix("utun") && ipv4(of: $0.ipv4) != nil }
        if let cidr = homeNetwork.flatMap(parseCIDR) {
            return tunnels.first { contains(cidr, ipv4(of: $0.ipv4)!) }?.ipv4
        }
        let localNets = Set(interfaces.filter { !$0.name.hasPrefix("utun") }.compactMap { ipv4(of: $0.ipv4) }.map { $0 & 0xFFFF_FF00 })
        return tunnels.first {
            let ip = ipv4(of: $0.ipv4)!
            return isPrivate(ip) && !localNets.contains(ip & 0xFFFF_FF00)
        }?.ipv4
    }

    /// The Mac's IPv4 interface addresses (loopback excluded), from getifaddrs.
    public static func currentIPv4Interfaces() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [InterfaceAddress] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  (cur.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append(InterfaceAddress(name: String(cString: cur.pointee.ifa_name), ipv4: String(cString: host)))
        }
        return result
    }

    static func ipv4(of s: String) -> UInt32? {
        var a = in_addr()
        guard inet_pton(AF_INET, s.trimmingCharacters(in: .whitespaces), &a) == 1 else { return nil }
        return UInt32(bigEndian: a.s_addr)
    }

    static func isPrivate(_ ip: UInt32) -> Bool {
        ip & 0xFF00_0000 == 0x0A00_0000 || ip & 0xFFF0_0000 == 0xAC10_0000 || ip & 0xFFFF_0000 == 0xC0A8_0000
    }

    static func parseCIDR(_ text: String) -> (net: UInt32, mask: UInt32)? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/")
        guard parts.count == 2, let ip = ipv4(of: String(parts[0])), let bits = Int(parts[1]), (1...32).contains(bits) else { return nil }
        let mask: UInt32 = bits == 32 ? .max : ~(UInt32.max >> UInt32(bits))
        return (ip & mask, mask)
    }

    static func contains(_ cidr: (net: UInt32, mask: UInt32), _ ip: UInt32) -> Bool { ip & cidr.mask == cidr.net }
}
