import Foundation
import Network
import PhoneCore

@MainActor final class UnavailableSIPEngine: SIPEngine {   // replaced in Task 8
    let events = AsyncStream<SIPEvent> { _ in }
    func register(_ config: SIPConfig) async throws { throw SIPError.failed("SIP engine not installed yet") }
    func unregister() {}
    func dial(_ number: String) throws -> Int { throw SIPError.failed("SIP engine not installed yet") }
    func answer(_ callId: Int) {}; func hangup(_ callId: Int) {}
    func setMuted(_ muted: Bool) {}; func sendDTMF(_ digits: String, callId: Int) {}
}
@MainActor final class UnavailableVPN: VPNControlling {   // replaced in Task 10
    func connect() async throws { throw SIPError.failed("VPN not installed yet") }
    func disconnect() async {}
}
@MainActor final class NoopPower: PowerAssertionControlling { func setPreventSleep(_ on: Bool) {} }   // replaced in Task 11

/// TCP probe of the TR-064 port (49000, plain HTTP) — no ATS involved.
struct TCPReachability: Reachability {
    let host: @Sendable () -> String
    func isFritzBoxReachable() async -> Bool {
        let conn = NWConnection(host: NWEndpoint.Host(host()), port: 49000, using: .tcp)
        return await withCheckedContinuation { cont in
            let box = OnceBox(cont)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: box.resume(true); conn.cancel()
                case .failed, .cancelled: box.resume(false)
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
