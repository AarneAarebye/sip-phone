// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

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
    /// Effective media-address mode (`.tunnelInterface` only together with `mediaBindAddress`).
    public var mediaAddressMode: MediaAddressMode
    /// Local IPv4 the audio socket binds to (and advertises) in `.tunnelInterface` mode.
    public var mediaBindAddress: String?
    public init(host: String, user: String, password: String,
                mediaAddressMode: MediaAddressMode = .automatic, mediaBindAddress: String? = nil) {
        self.host = host; self.user = user; self.password = password
        self.mediaAddressMode = mediaAddressMode; self.mediaBindAddress = mediaBindAddress
    }
    public var description: String {
        "SIPConfig(host: \(host), user: \(user), password: <redacted>, media: \(mediaAddressMode.rawValue)\(mediaBindAddress.map { " \($0)" } ?? ""))"
    }
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
    /// True while the engine still knows the call and it is not disconnected.
    func isCallActive(_ callId: Int) -> Bool
    /// Last resort after a hang-up got no end event: terminate the call locally and forget it, so a half-dead
    /// call cannot linger. Any end event it produces arrives for a call AppCore already ended (ignored).
    func forceEnd(_ callId: Int)
    func setMuted(_ muted: Bool)
    /// Sends with `method` and returns its outcome.
    func sendDTMF(_ digits: String, callId: Int, method: DTMFMethod) -> [DTMFOutcome]
    /// The Mac's network path changed (VPN up/down, Wi-Fi switch, wake): rebind the SIP transport so the next
    /// registration uses the new local address. AppCore calls it only while no call is live.
    func networkChanged()
}
@MainActor public protocol VPNControlling: AnyObject {
    func connect() async throws
    func disconnect() async
}
public protocol Reachability: Sendable {
    /// The FRITZ!Box answers over whatever route the system picks (including the VPN).
    func isFritzBoxReachable() async -> Bool
    /// "Am I home?": the FRITZ!Box answers over a physical interface (Wi-Fi/Ethernet), never through a VPN.
    func isFritzBoxReachableDirectly() async -> Bool
}
@MainActor public protocol PowerAssertionControlling: AnyObject { func setPreventSleep(_ on: Bool) }
