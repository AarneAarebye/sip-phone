// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import XCTest
import NetworkExtension
import PhoneCore
@testable import VPN

/// Dummy keys only (all-zero / all-0x02 32-byte values): never a real WireGuard config.
private let keyA = Data(count: 32).base64EncodedString()
private let keyB = Data(repeating: 2, count: 32).base64EncodedString()

private func config(address: String = "192.168.65.204/32", allowed: String = "0.0.0.0/0, ::/0") -> String {
    """
    [Interface]
    PrivateKey = \(keyA)
    Address = \(address)
    DNS = 192.168.65.1

    [Peer]
    PublicKey = \(keyB)
    PresharedKey = \(keyA)
    AllowedIPs = \(allowed)
    Endpoint = example.invalid:51820
    PersistentKeepalive = 25
    """
}

private func allowedIPs(_ text: String) -> [String] {
    text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.lowercased().hasPrefix("allowedips") }
        .map { String($0[$0.index(after: $0.firstIndex(of: "=")!)...]).trimmingCharacters(in: .whitespaces) }
}

final class SplitTunnelConfigTests: XCTestCase {
    func testFullTunnelBecomesHomeNetworkAndKeepsEverythingElse() throws {
        let original = config()
        let out = try SplitTunnelConfig.rewrite(original, homeNetwork: nil)
        XCTAssertEqual(allowedIPs(out), ["192.168.65.0/24"])
        XCTAssertEqual(out, original.replacingOccurrences(of: "AllowedIPs = 0.0.0.0/0, ::/0", with: "AllowedIPs = 192.168.65.0/24"))
        XCTAssertEqual(try WireGuardConfigCheck.validate(out), "example.invalid:51820")
    }

    func testAddressPrefixes() throws {
        for address in ["192.168.65.204/32", "192.168.65.204/24", "192.168.65.204"] {
            XCTAssertEqual(allowedIPs(try SplitTunnelConfig.rewrite(config(address: address), homeNetwork: nil)), ["192.168.65.0/24"], address)
        }
    }

    func testOverrideCIDRIsNormalizedAndWins() throws {
        let out = try SplitTunnelConfig.rewrite(config(), homeNetwork: " 10.1.2.3/16 ")
        XCTAssertEqual(allowedIPs(out), ["10.1.0.0/16"])
        XCTAssertThrowsError(try SplitTunnelConfig.rewrite(config(), homeNetwork: "10.1.2.3")) { error in
            guard case VPNError.invalidConfig(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("CIDR"))
        }
        XCTAssertEqual(allowedIPs(try SplitTunnelConfig.rewrite(config(), homeNetwork: "")), ["192.168.65.0/24"])
    }

    func testMultiplePeersAndRepeatedOrMissingAllowedIPs() throws {
        let text = config() + """

        AllowedIPs = 10.0.0.0/8

        [Peer]
        PublicKey = \(keyA)
        Endpoint = other.invalid:51820

        """
        let out = try SplitTunnelConfig.rewrite(text, homeNetwork: nil)
        XCTAssertEqual(allowedIPs(out), ["192.168.65.0/24", "192.168.65.0/24"])
        // the line is added inside the second peer, before the trailing blank line
        XCTAssertTrue(out.hasSuffix("Endpoint = other.invalid:51820\nAllowedIPs = 192.168.65.0/24\n"), out.suffix(80).description)
    }

    func testCommentsAndWhitespaceArePreserved() throws {
        let text = """
        # exported by the FRITZ!Box
        [Interface]
          Address = 192.168.65.204/24 # tunnel address
        PrivateKey = \(keyA)

        [peer]
        PublicKey = \(keyB)
        # AllowedIPs = 1.2.3.4/32
          allowedips=0.0.0.0/0 # everything
        Endpoint = example.invalid:51820
        """
        let out = try SplitTunnelConfig.rewrite(text, homeNetwork: nil)
        XCTAssertTrue(out.contains("# AllowedIPs = 1.2.3.4/32"))           // commented-out line untouched
        XCTAssertTrue(out.contains("  Address = 192.168.65.204/24 # tunnel address"))
        XCTAssertTrue(out.hasPrefix("# exported by the FRITZ!Box\n"))
        XCTAssertFalse(out.contains("0.0.0.0/0"))
        XCTAssertEqual(allowedIPs(out).last, "192.168.65.0/24")
    }

    func testCRLFLineEndingsAreKept() throws {
        let text = config().replacingOccurrences(of: "\n", with: "\r\n")
        let out = try SplitTunnelConfig.rewrite(text, homeNetwork: nil)
        XCTAssertTrue(out.contains("AllowedIPs = 192.168.65.0/24\r\n"))
        XCTAssertFalse(out.contains("0.0.0.0/0"))
    }

    func testNoPeerIsAnError() {
        let text = config().components(separatedBy: "[Peer]")[0]
        XCTAssertThrowsError(try SplitTunnelConfig.rewrite(text, homeNetwork: nil)) { error in
            XCTAssertEqual(error as? VPNError, .invalidConfig("no [Peer] section"))
        }
    }

    func testMissingAddressIsAnErrorWithoutValues() {
        XCTAssertThrowsError(try SplitTunnelConfig.rewrite(config(address: "not-an-ip"), homeNetwork: nil)) { error in
            guard case VPNError.invalidConfig(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("Address"))
            XCTAssertFalse(error.localizedDescription.contains(keyA))
        }
    }

    func testAddressWithSeveralEntries() throws {
        // IPv4 present: IPv6 is dropped from AllowedIPs.
        let mixed = try SplitTunnelConfig.rewrite(config(address: "fd00:1:2:3::cc/128, 192.168.65.204/32"), homeNetwork: nil)
        XCTAssertEqual(allowedIPs(mixed), ["192.168.65.0/24"])
        // IPv6 only: its /64.
        let v6 = try SplitTunnelConfig.rewrite(config(address: "fd00:1:2:3::cc/128"), homeNetwork: nil)
        XCTAssertEqual(allowedIPs(v6), ["fd00:1:2:3::/64"])
        // Several Address lines are all considered.
        let twoLines = config(address: "fd00::1/128\nAddress = 10.20.30.40/32")
        XCTAssertEqual(allowedIPs(try SplitTunnelConfig.rewrite(twoLines, homeNetwork: nil)), ["10.20.30.0/24"])
    }

    func testNormalizedCIDR() {
        XCTAssertEqual(SplitTunnelConfig.normalizedCIDR("192.168.65.0/24"), "192.168.65.0/24")
        XCTAssertEqual(SplitTunnelConfig.normalizedCIDR("192.168.65.77/24"), "192.168.65.0/24")
        XCTAssertEqual(SplitTunnelConfig.normalizedCIDR("192.168.65.77/32"), "192.168.65.77/32")
        XCTAssertEqual(SplitTunnelConfig.normalizedCIDR("172.16.5.4/12"), "172.16.0.0/12")
        XCTAssertEqual(SplitTunnelConfig.normalizedCIDR("fd00:1:2:3::9/64"), "fd00:1:2:3::/64")
        for bad in ["", "192.168.65.0", "192.168.65.0/0", "192.168.65.0/33", "192.168.65/24", "fritz.box/24",
                    "192.168.65.0/24/1", "192.168.65.0/+24", "::/0", "::/129", "256.1.1.1/24"] {
            XCTAssertNil(SplitTunnelConfig.normalizedCIDR(bad), bad)
        }
    }
}

final class SplitTunnelHandoffTests: XCTestCase {
    func testSplitFlagTravelsInStartOptions() {
        XCTAssertTrue(TunnelConfigHandoff.isSplitTunnel(startOptions: TunnelConfigHandoff.startOptions(config: "x", splitTunnel: true)))
        XCTAssertFalse(TunnelConfigHandoff.isSplitTunnel(startOptions: TunnelConfigHandoff.startOptions(config: "x")))
        XCTAssertFalse(TunnelConfigHandoff.isSplitTunnel(startOptions: nil))
    }
}

/// Records the start options; connects at once.
@MainActor
private final class RecordingBackend: TunnelBackend {
    var options: [String: NSObject]?
    var status: NEVPNStatus = .disconnected
    func activateExtension() async throws {}
    func configure(serverAddress: String) async throws {}
    func start(options: [String: NSObject]) throws { self.options = options; status = .connected }
    func stop() async { status = .disconnected }
    func lastDisconnectReason() async -> String? { nil }
}

private final class Secrets: SecretStore, @unchecked Sendable {
    var values: [String: String] = [:]
    func get(_ key: String) -> String? { values[key] }
    func contains(_ key: String) -> Bool { values[key] != nil }
    func set(_ value: String?, for key: String) throws { values[key] = value }
}

@MainActor
final class VPNManagerRoutingTests: XCTestCase {
    private func start(_ routing: TunnelRouting) async throws -> [String: NSObject]? {
        let s = Secrets(); s.values[SecretKey.wireguardConfig] = config()
        let backend = RecordingBackend()
        try await VPNManager(secrets: s, backend: backend, routing: { routing }).connect()
        return backend.options
    }

    func testSplitModeHandsOverRewrittenConfigAndFlag() async throws {
        let options = try await start(TunnelRouting(splitTunnel: true))
        XCTAssertTrue(TunnelConfigHandoff.isSplitTunnel(startOptions: options))
        XCTAssertEqual(allowedIPs(TunnelConfigHandoff.config(fromStartOptions: options) ?? ""), ["192.168.65.0/24"])
    }

    func testFullModeHandsOverConfigUnchanged() async throws {
        let options = try await start(.full)
        XCTAssertFalse(TunnelConfigHandoff.isSplitTunnel(startOptions: options))
        XCTAssertEqual(TunnelConfigHandoff.config(fromStartOptions: options), config())
    }

    func testInvalidOverrideFailsBeforeStarting() async {
        do { _ = try await start(TunnelRouting(splitTunnel: true, homeNetwork: "home")); XCTFail("expected error") }
        catch { guard case VPNError.invalidConfig = error else { return XCTFail("\(error)") } }
    }
}
