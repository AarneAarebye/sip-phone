import Foundation
import PhoneCore
import PJBridge

@MainActor
public final class PJSIPEngine: NSObject, SIPEngine, PJBridgeDelegate {
    public let events: AsyncStream<SIPEvent>
    private let continuation: AsyncStream<SIPEvent>.Continuation
    private let bridge = PJBridge()
    private var started = false
    private var pending: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?

    public override init() {
        let p = AsyncStream<SIPEvent>.makeStream()
        events = p.stream; continuation = p.continuation
        super.init()
        bridge.delegate = self
    }

    public func register(_ config: SIPConfig) async throws {
        resolve(.failure(SIPError.failed("superseded by a new registration")))
        if !started {
            do { try bridge.start() } catch { throw SIPError.failed(error.localizedDescription) }
            started = true
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pending = c
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.resolve(.failure(SIPError.timeout))
            }
            do { try bridge.registerAccount(withHost: config.host, user: config.user, password: config.password) }
            catch { resolve(.failure(SIPError.failed(error.localizedDescription))) }
        }
    }

    private func resolve(_ result: Result<Void, Error>) {
        timeoutTask?.cancel(); timeoutTask = nil
        guard let c = pending else { return }
        pending = nil
        c.resume(with: result)
    }

    public func unregister() {
        resolve(.failure(SIPError.failed("unregistered")))
        bridge.unregisterAccount()
        continuation.yield(.registration(.unregistered))
    }

    /// Stops PJSIP entirely. The engine cannot be used afterwards.
    public func shutdown() {
        resolve(.failure(SIPError.failed("shut down")))
        bridge.shutdown(); started = false
        continuation.finish()
    }

    public func dial(_ number: String) throws -> Int {
        do { return try bridge.dial(number).intValue }
        catch { throw SIPError.failed(error.localizedDescription) }
    }
    public func answer(_ callId: Int) { bridge.answer(callId) }
    public func hangup(_ callId: Int) { bridge.hangup(callId) }
    public func setMuted(_ muted: Bool) { bridge.setMuted(muted) }
    public func sendDTMF(_ digits: String, callId: Int) { bridge.sendDTMF(digits, callId: callId) }

    // MARK: PJBridgeDelegate (always invoked on the main thread)

    public nonisolated func registrationChanged(_ statusCode: Int, reason: String) {
        MainActor.assumeIsolated {
            if pending != nil {
                switch Self.pendingOutcome(statusCode: statusCode, reason: reason) {
                case .success?: resolve(.success(()))
                case .failure(let e)?: resolve(.failure(e))
                case nil: break
                }
            } else if let ev = Self.registrationEvent(statusCode: statusCode, reason: reason) {
                // 401/403 arrive here as .failed(code:); AppCore maps them to .authFailed.
                continuation.yield(ev)
            }
        }
    }

    enum PendingOutcome: Equatable { case success, failure(SIPError) }

    /// Result for a pending register() call; nil = not final yet.
    nonisolated static func pendingOutcome(statusCode: Int, reason: String) -> PendingOutcome? {
        switch statusCode {
        case 200..<300: return .success
        case 401, 403: return .failure(.authFailed)
        case 300...: return .failure(.failed("\(statusCode) \(reason)"))
        default: return nil
        }
    }

    /// Event for a registration change when no register() is pending; nil = not final yet.
    nonisolated static func registrationEvent(statusCode: Int, reason: String) -> SIPEvent? {
        guard statusCode >= 200 else { return nil }
        return .registration(statusCode < 300 ? .registered : .failed(code: statusCode, reason: reason))
    }
    public nonisolated func incomingCall(_ callId: Int, from remote: String, called: String) {
        MainActor.assumeIsolated {
            continuation.yield(.incomingCall(id: callId, remote: Self.userPart(of: remote), called: Self.calledNumber(from: called)))
        }
    }

    /// Own number from a P-Called-Party-ID value or To URI; nil when empty.
    nonisolated static func calledNumber(from raw: String) -> String? {
        let n = userPart(of: raw.trimmingCharacters(in: .whitespaces))
        return n.isEmpty ? nil : n
    }
    public nonisolated func callStateChanged(_ callId: Int, state: String, statusCode code: Int, reason: String) {
        MainActor.assumeIsolated {
            let s: CallState
            switch state {
            case "calling": s = .calling
            case "ringing": s = .ringing
            case "connected": s = .connected
            default: s = .ended(code: code, reason: reason)
            }
            continuation.yield(.callState(id: callId, s))
        }
    }

    /// "\"Name\" <sip:0301234@fritz.box>" -> "0301234"
    nonisolated static func userPart(of uri: String) -> String {
        guard let r = uri.range(of: "sip:") else { return uri }
        let rest = uri[r.upperBound...]
        return String(rest.prefix { $0 != "@" && $0 != ">" && $0 != ";" })
    }
}
