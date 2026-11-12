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

    private static func error(_ message: String) -> NSError {
        NSError(domain: "com.aarneaarebye.sipphone.PacketTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
