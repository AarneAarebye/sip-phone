// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import Foundation
import Network

/// Connection parameters for the "am I home?" probe: the connection may use a physical interface only.
///
/// Network.framework reports VPN tunnels (utun, including our WireGuard packet tunnel) as interface type
/// `.other`; Wi-Fi is `.wifi`, Ethernet `.wiredEthernet`. Two layers keep the probe off the VPN:
/// 1. the connection is bound to one physical interface (`requiredInterface`, i.e. scoped routing and the
///    interface's own DNS resolver), so the tunnel's route to the home network is never consulted;
/// 2. `.other` and `.loopback` are prohibited as well, in case no interface could be bound.
public enum DirectPath {
    public static let prohibitedTypes: [NWInterface.InterfaceType] = [.other, .loopback]

    /// Interface types that are never a VPN tunnel.
    public static func isPhysical(_ type: NWInterface.InterfaceType) -> Bool {
        switch type {
        case .wifi, .wiredEthernet, .cellular: return true
        default: return false
        }
    }

    public static func excludeVPN(_ parameters: NWParameters, boundTo interface: NWInterface? = nil) {
        parameters.prohibitedInterfaceTypes = prohibitedTypes
        if let interface, isPhysical(interface.type) { parameters.requiredInterface = interface }
    }

    /// The physical interfaces currently available (Wi-Fi/Ethernet first), from a path monitor that itself
    /// excludes tunnels. Empty when none is up or the system does not answer within `timeout`.
    public static func physicalInterfaces(timeout: TimeInterval = 1) async -> [NWInterface] {
        let monitor = NWPathMonitor(prohibitedInterfaceTypes: prohibitedTypes)
        return await withCheckedContinuation { cont in
            let once = Once(cont)
            monitor.pathUpdateHandler = { path in
                let found = path.availableInterfaces.filter { isPhysical($0.type) }
                once.resume(found.filter { $0.type != .cellular } + found.filter { $0.type == .cellular })
                monitor.cancel()
            }
            monitor.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume([]); monitor.cancel() }
        }
    }

    private final class Once: @unchecked Sendable {
        private var cont: CheckedContinuation<[NWInterface], Never>?
        private let lock = NSLock()
        init(_ c: CheckedContinuation<[NWInterface], Never>) { cont = c }
        func resume(_ v: [NWInterface]) { lock.lock(); let c = cont; cont = nil; lock.unlock(); c?.resume(returning: v) }
    }
}
