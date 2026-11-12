import Foundation
import Network
import PhoneCore
import FritzTR064

@MainActor final class NoopPower: PowerAssertionControlling { func setPreventSleep(_ on: Bool) {} }   // replaced in Task 11

/// TCP probe of the TR-064 TLS port the client uses — no ATS involved.
struct TCPReachability: Reachability {
    let host: @Sendable () -> String
    func isFritzBoxReachable() async -> Bool {
        let conn = NWConnection(host: NWEndpoint.Host(host()), port: NWEndpoint.Port(rawValue: UInt16(FritzTR064Client.defaultPort))!, using: .tcp)
        return await withCheckedContinuation { cont in
            let box = OnceBox(cont)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: box.resume(true); conn.cancel()
                case .waiting: box.resume(false); conn.cancel()
                case .failed: box.resume(false); conn.cancel()
                case .cancelled: box.resume(false)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { box.resume(false); conn.cancel() }
        }
    }
}
private final class OnceBox: @unchecked Sendable {
    private var cont: CheckedContinuation<Bool, Never>?
    private let lock = NSLock()
    init(_ c: CheckedContinuation<Bool, Never>) { cont = c }
    func resume(_ v: Bool) { lock.lock(); let c = cont; cont = nil; lock.unlock(); c?.resume(returning: v) }
}
