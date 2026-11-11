import Foundation

public enum RegistrationState: Equatable, Sendable { case unregistered, registered, failed(code: Int, reason: String) }
public enum CallState: Equatable, Sendable { case calling, ringing, connected, ended(code: Int, reason: String) }
public enum SIPEvent: Equatable, Sendable {
    case registration(RegistrationState)
    case incomingCall(id: Int, remote: String)
    case callState(id: Int, CallState)
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
    func sendDTMF(_ digits: String, callId: Int)
}
@MainActor public protocol VPNControlling: AnyObject {
    func connect() async throws
    func disconnect() async
}
public protocol Reachability: Sendable { func isFritzBoxReachable() async -> Bool }
@MainActor public protocol PowerAssertionControlling: AnyObject { func setPreventSleep(_ on: Bool) }
