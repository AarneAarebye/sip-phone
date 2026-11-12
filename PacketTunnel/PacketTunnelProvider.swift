// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import NetworkExtension
import os
import VPN
import WireGuardKit

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let log = Logger(subsystem: "com.aarneaarebye.sipphone.PacketTunnel", category: "tunnel")

    // WireGuardKit's log lines carry endpoints/DNS/network state, never keys or the config text.
    private lazy var adapter = WireGuardAdapter(with: self) { level, message in
        Self.log.log(level: level == .error ? .error : .debug, "WireGuard: \(message, privacy: .public)")
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // The config only arrives in the start options from SIP Phone (see TunnelConfigHandoff).
        guard let text = TunnelConfigHandoff.config(fromStartOptions: options) else {
            Self.log.error("Start without configuration (not started by SIP Phone)")
            return completionHandler(Self.error("Start the VPN from SIP Phone"))
        }
        let config: TunnelConfiguration
        do { config = try TunnelConfiguration(fromWgQuickConfig: text, called: "FRITZ!Box") }
        catch {
            // The parse error can contain config values: log and report only that parsing failed.
            Self.log.error("Invalid WireGuard configuration")
            return completionHandler(Self.error("Invalid WireGuard configuration"))
        }
        // Split tunnel (the app already narrowed AllowedIPs to the home network): the config's DNS servers
        // answer only for the home domain, so ordinary lookups keep using the Mac's own DNS.
        let split = TunnelConfigHandoff.isSplitTunnel(startOptions: options)
        adapter.dnsMatchDomains = split ? Self.uniqued(TunnelConfigHandoff.splitDNSDomains + config.interface.dnsSearch) : nil
        Self.log.log("Starting \(split ? "split" : "full", privacy: .public) tunnel")
        adapter.start(tunnelConfiguration: config) { adapterError in
            if let adapterError {
                Self.log.error("Adapter start failed: \(String(describing: adapterError), privacy: .public)")
                if case .dnsResolution = adapterError {
                    completionHandler(Self.error("Could not resolve the WireGuard endpoint"))
                } else {
                    completionHandler(Self.error("WireGuard could not start"))
                }
            } else {
                Self.log.log("Tunnel started")
                completionHandler(nil)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        adapter.stop { _ in completionHandler() }
    }

    private static func uniqued(_ domains: [String]) -> [String] {
        var seen = Set<String>()
        return domains.filter { seen.insert($0.lowercased()).inserted }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "com.aarneaarebye.sipphone.PacketTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
