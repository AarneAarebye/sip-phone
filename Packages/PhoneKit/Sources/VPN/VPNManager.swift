// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import Foundation
import NetworkExtension
import PhoneCore

public enum VPNError: Error, Equatable, LocalizedError {
    case notConfigured, invalidConfig(String), needsApproval, rebootRequired, activationFailed(String)
    case timeout, stopped(String?)
    public var errorDescription: String? {
        switch self {
        case .notConfigured: "No WireGuard configuration in Settings"
        case .invalidConfig(let why): "Invalid WireGuard configuration: \(why)"
        case .needsApproval:
            "Allow the SIP Phone network extension in System Settings > General > Login Items & Extensions > Network Extensions"
        case .rebootRequired: "Restart the Mac to finish installing the SIP Phone network extension"
        case .activationFailed(let why): "Network extension could not be installed: \(why)"
        case .timeout: "VPN did not connect in time"
        case .stopped(let why): why.map { "VPN stopped: \($0)" } ?? "VPN stopped unexpectedly"
        }
    }
}

/// The system side of the tunnel (extension activation, VPN preferences, session). A seam so the
/// connect/disconnect/cancellation logic can be unit-tested without NetworkExtension.
@MainActor protocol TunnelBackend: AnyObject {
    func activateExtension() async throws
    /// Creates or updates the VPN configuration (no secrets in it).
    func configure(serverAddress: String) async throws
    var status: NEVPNStatus { get }
    func start(options: [String: NSObject]) throws
    /// Stops the tunnel if one exists (loads the configuration first if needed).
    func stop() async
    func lastDisconnectReason() async -> String?
}

/// Starts/stops the full-tunnel WireGuard VPN implemented by the PacketTunnel system extension.
@MainActor
public final class VPNManager: VPNControlling {
    private let secrets: SecretStore
    private let backend: TunnelBackend
    /// The one shared connect attempt; callers wait on it via `waiters`.
    private var attempt: (id: UUID, task: Task<Void, Never>)?
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    public convenience init(secrets: SecretStore, extensionBundleId: String) {
        self.init(secrets: secrets, backend: SystemTunnelBackend(extensionBundleId: extensionBundleId))
    }

    init(secrets: SecretStore, backend: TunnelBackend) {
        self.secrets = secrets; self.backend = backend
    }

    /// Safe to call repeatedly: returns at once when the tunnel is up; concurrent callers join one attempt.
    /// Cancelling a caller only stops that caller's wait; the shared attempt is cancelled by `disconnect()` alone.
    public func connect() async throws {
        if attempt == nil { startAttempt() }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                waiters[id] = cont
                if Task.isCancelled { resumeWaiter(id, with: .failure(CancellationError())) }
            }
        } onCancel: {
            Task { @MainActor in self.resumeWaiter(id, with: .failure(CancellationError())) }
        }
    }

    /// Cancels and awaits any attempt in progress, then stops the tunnel, so no tunnel can be
    /// started after this returns (and one the attempt already started is stopped).
    public func disconnect() async {
        if let running = attempt {
            running.task.cancel()
            await running.task.value
        }
        await backend.stop()
    }

    // MARK: Attempt

    private func startAttempt() {
        let id = UUID()
        let task = Task {
            let result: Result<Void, Error>
            do { try await self.performConnect(); result = .success(()) } catch { result = .failure(error) }
            self.finishAttempt(id, result)
        }
        attempt = (id, task)
    }

    private func finishAttempt(_ id: UUID, _ result: Result<Void, Error>) {
        guard attempt?.id == id else { return }
        attempt = nil
        let ready = waiters; waiters = [:]
        ready.values.forEach { $0.resume(with: result) }
    }

    private func resumeWaiter(_ id: UUID, with result: Result<Void, Error>) {
        waiters.removeValue(forKey: id)?.resume(with: result)
    }

    private func performConnect() async throws {
        // Validate before touching the system (no extension activation, no VPN preferences).
        guard let config = secrets.get(SecretKey.wireguardConfig),
              !config.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VPNError.notConfigured }
        let endpoint = try WireGuardConfigCheck.validate(config)

        try await backend.activateExtension()
        try Task.checkCancellation()
        try await backend.configure(serverAddress: endpoint)
        try Task.checkCancellation()

        // Let a previous stop finish before starting again.
        var waits = 0
        while backend.status == .disconnecting && waits < 20 { waits += 1; try await Task.sleep(for: .milliseconds(250)) }
        switch backend.status {
        case .connected: return
        case .connecting, .reasserting: break   // an earlier start is still in progress: just wait for it
        default:
            try Task.checkCancellation()
            try backend.start(options: TunnelConfigHandoff.startOptions(config: config))
        }

        let start = ContinuousClock.now
        var sawActivity = false
        while true {
            let status = backend.status
            if status != .disconnected && status != .invalid { sawActivity = true }
            switch Self.progress(status: status, sawActivity: sawActivity, elapsed: ContinuousClock.now - start) {
            case .connected: return
            case .failed: throw VPNError.stopped(await backend.lastDisconnectReason())
            case .timedOut: await backend.stop(); throw VPNError.timeout
            case .waiting: try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    // MARK: Pure logic (unit-tested)

    enum Progress: Equatable { case connected, failed, waiting, timedOut }

    nonisolated static let connectTimeout: Duration = .seconds(20)
    /// Right after `startTunnel` the status can still read `.disconnected` briefly; only treat it as a
    /// failure once the tunnel was seen starting, or after a grace period.
    nonisolated static let startGrace: Duration = .seconds(3)

    nonisolated static func progress(status: NEVPNStatus, sawActivity: Bool, elapsed: Duration) -> Progress {
        switch status {
        case .connected: return .connected
        case .disconnected, .invalid:
            if sawActivity || elapsed >= startGrace { return .failed }
        default: break
        }
        return elapsed >= connectTimeout ? .timedOut : .waiting
    }
}

/// Production backend: OSSystemExtensionRequest + NETunnelProviderManager.
@MainActor
final class SystemTunnelBackend: TunnelBackend {
    private let extensionBundleId: String
    private let displayName = "FRITZ!Box"
    private var manager: NETunnelProviderManager?
    private var activation: SystemExtensionActivation?

    init(extensionBundleId: String) { self.extensionBundleId = extensionBundleId }

    func activateExtension() async throws {
        let a = activation ?? SystemExtensionActivation(extensionBundleId: extensionBundleId)
        activation = a
        switch await a.current() {
        case .activated: return
        case .needsApproval: throw VPNError.needsApproval
        case .rebootRequired: throw VPNError.rebootRequired
        case .failed(let why): activation = nil; throw VPNError.activationFailed(why)   // submit a fresh request next time
        case .noAnswer:
            try Task.checkCancellation()
            throw VPNError.activationFailed("macOS did not answer the activation request")
        }
    }

    private func loadManager() async throws -> NETunnelProviderManager? {
        try await NETunnelProviderManager.loadAllFromPreferences().first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == extensionBundleId
        }
    }

    func configure(serverAddress: String) async throws {
        let m = try await loadManager() ?? NETunnelProviderManager()
        let proto = (m.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        if !m.isEnabled || m.localizedDescription != displayName || proto.providerBundleIdentifier != extensionBundleId
            || proto.serverAddress != serverAddress || proto.passwordReference != nil || proto.providerConfiguration != nil {
            proto.providerBundleIdentifier = extensionBundleId
            proto.serverAddress = serverAddress
            proto.passwordReference = nil
            proto.providerConfiguration = nil
            m.protocolConfiguration = proto
            m.localizedDescription = displayName
            m.isEnabled = true
            try await m.saveToPreferences()   // first time: macOS asks the user to allow the VPN configuration
            try await m.loadFromPreferences()
        }
        manager = m
    }

    var status: NEVPNStatus { manager?.connection.status ?? .invalid }

    func start(options: [String: NSObject]) throws {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            throw VPNError.stopped("not a tunnel provider session")
        }
        try session.startTunnel(options: options)
    }

    func stop() async {
        if manager == nil { manager = try? await loadManager() }
        manager?.connection.stopVPNTunnel()
    }

    func lastDisconnectReason() async -> String? {
        guard let connection = manager?.connection else { return nil }
        return await withCheckedContinuation { cont in
            connection.fetchLastDisconnectError { cont.resume(returning: $0?.localizedDescription) }
        }
    }
}
