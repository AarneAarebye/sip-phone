// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import Foundation
import Network
import Security
import PhoneCore
import FritzTR064
import SystemAdapters

/// Probes the TR-064 TLS port the client uses (no ATS involved).
///
/// With a pinned certificate the listener only counts if it is OUR FRITZ!Box: a TLS handshake is made and the
/// leaf certificate's SHA-256 (the pin format of `URLSessionTransport`) must match the stored pin. Another
/// FRITZ!Box on a visited network then counts as unreachable, so the VPN is started. Without a stored pin the
/// probe is a plain TCP connect.
///
/// The direct variant ("am I home?") additionally prohibits VPN interfaces (see `DirectPath`), so it succeeds
/// only when the box answers over Wi-Fi/Ethernet, never through our tunnel.
struct FritzBoxReachability: Reachability {
    let host: @Sendable () -> String
    let pinned: @Sendable () -> String?

    func isFritzBoxReachable() async -> Bool { await probe(direct: false, via: nil) }

    /// Tries each physical interface (bound to it, VPN types prohibited); true as soon as one reaches the box.
    func isFritzBoxReachableDirectly() async -> Bool {
        for interface in await DirectPath.physicalInterfaces() where await probe(direct: true, via: interface) {
            return true
        }
        return false
    }

    private func probe(direct: Bool, via interface: NWInterface?) async -> Bool {
        let parameters: NWParameters
        var timeout: TimeInterval
        if let pin = pinned(), !pin.isEmpty {
            let tls = NWProtocolTLS.Options()
            // The FRITZ!Box certificate is self-signed: the pin, not the system trust store, decides.
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                let leaf = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first
                complete(CertificatePinning.probeMatchesPin(leafDER: leaf.map { SecCertificateCopyData($0) as Data },
                                                            pinned: pin))
            }, DispatchQueue.global())
            parameters = NWParameters(tls: tls)
            timeout = 5
        } else {
            parameters = .tcp
            timeout = 3
        }
        if direct {
            DirectPath.excludeVPN(parameters, boundTo: interface)
            timeout = 3
        }
        let conn = NWConnection(host: NWEndpoint.Host(host()),
                                port: NWEndpoint.Port(rawValue: UInt16(FritzTR064Client.defaultPort))!, using: parameters)
        return await withCheckedContinuation { cont in
            let box = OnceBox(cont)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: box.resume(true); conn.cancel()      // TLS: handshake done and the pin matched
                case .waiting: box.resume(false); conn.cancel()
                case .failed: box.resume(false); conn.cancel()    // includes a certificate that is not ours
                case .cancelled: box.resume(false)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { box.resume(false); conn.cancel() }
        }
    }
}

private final class OnceBox: @unchecked Sendable {
    private var cont: CheckedContinuation<Bool, Never>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<Bool, Never>) { cont = c }
    func resume(_ v: Bool) { lock.lock(); let c = cont; cont = nil; lock.unlock(); c?.resume(returning: v) }
}
