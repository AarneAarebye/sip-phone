import Foundation

public enum RegistrationState: Equatable, Sendable { case unregistered, registered, failed(code: Int, reason: String) }
public enum CallState: Equatable, Sendable { case calling, ringing, connected, ended(code: Int, reason: String) }
public enum SIPEvent: Equatable, Sendable {
    case registration(RegistrationState)
    case incomingCall(id: Int, remote: String, called: String?)
    case callState(id: Int, CallState)
    /// The call's audio became active (sent again after a re-INVITE).
    case callMedia(id: Int, CallMediaInfo)
}

/// What the negotiated audio stream says about RFC 2833 telephone-event. Contains no digits.
public struct CallMediaInfo: Equatable, Sendable {
    /// Payload type we send telephone-event with, taken from the remote SDP; nil = remote did not offer it.
    public var remoteTelephoneEventPT: Int?
    /// Payload type we receive telephone-event on, taken from our local SDP; nil = we did not offer it.
    public var localTelephoneEventPT: Int?
    public var codec: String
    public init(remoteTelephoneEventPT: Int?, localTelephoneEventPT: Int?, codec: String) {
        self.remoteTelephoneEventPT = remoteTelephoneEventPT; self.localTelephoneEventPT = localTelephoneEventPT; self.codec = codec
    }
    public var summary: String {
        func pt(_ v: Int?) -> String { v.map { "yes, payload type \($0)" } ?? "no" }
        return "remote telephone-event: \(pt(remoteTelephoneEventPT)); local: \(pt(localTelephoneEventPT)); codec \(codec)"
    }
}

/// Result of sending keypad digits with one wire method. `error` is the PJSIP status text, never the digits.
public struct DTMFOutcome: Equatable, Sendable {
    public var method: DTMFMethod
    public var error: String?
    public init(method: DTMFMethod, error: String? = nil) { self.method = method; self.error = error }
}
public struct SIPConfig: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var host: String, user: String, password: String
    public init(host: String, user: String, password: String) { self.host = host; self.user = user; self.password = password }
    public var description: String { "SIPConfig(host: \(host), user: \(user), password: <redacted>)" }
    public var debugDescription: String { description }
}
public enum SIPError: Error, Equatable { case authFailed, timeout, failed(String) }

/// `events` is a single long-lived stream owned by the engine; AppCore starts consuming it once, in `start()`.
/// After `AppCore.shutdown()` the stream is not re-iterated: restarting means a new engine and a new AppCore.
@MainActor public protocol SIPEngine: AnyObject {
    var events: AsyncStream<SIPEvent> { get }
    func register(_ config: SIPConfig) async throws
    func unregister()
    func dial(_ number: String) throws -> Int
    func answer(_ callId: Int)
    func hangup(_ callId: Int)
    func setMuted(_ muted: Bool)
    /// Sends with each of `method.wireMethods` in order and returns one outcome per wire method.
    func sendDTMF(_ digits: String, callId: Int, method: DTMFMethod) -> [DTMFOutcome]
}
@MainActor public protocol VPNControlling: AnyObject {
    func connect() async throws
    func disconnect() async
}
public protocol Reachability: Sendable { func isFritzBoxReachable() async -> Bool }
@MainActor public protocol PowerAssertionControlling: AnyObject { func setPreventSleep(_ on: Bool) }
