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
            "Allow the FritzPhone network extension in System Settings > General > Login Items & Extensions > Network Extensions"
        case .rebootRequired: "Restart the Mac to finish installing the FritzPhone network extension"
        case .activationFailed(let why): "Network extension could not be installed: \(why)"
        case .timeout: "VPN did not connect in time"
        case .stopped(let why): why.map { "VPN stopped: \($0)" } ?? "VPN stopped unexpectedly"
        }
    }
}

/// Starts/stops the full-tunnel WireGuard VPN implemented by the PacketTunnel system extension.
@MainActor
public final class VPNManager: VPNControlling {
    private let secrets: SecretStore
    private let extensionBundleId: String
    private let displayName = "FRITZ!Box"
    private var manager: NETunnelProviderManager?
    private var activation: SystemExtensionActivation?
    private var inFlight: Task<Void, Error>?

    public init(secrets: SecretStore, extensionBundleId: String) {
        self.secrets = secrets; self.extensionBundleId = extensionBundleId
    }

    /// Safe to call repeatedly: returns at once when the tunnel is up; concurrent callers join one attempt.
    public func connect() async throws {
        let task: Task<Void, Error>
        if let inFlight { task = inFlight } else {
            task = Task { try await self.performConnect() }
            inFlight = task
        }
        defer { if inFlight == task { inFlight = nil } }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public func disconnect() async {
        inFlight?.cancel()
        var m = manager
        if m == nil { m = try? await loadManager() }
        m?.connection.stopVPNTunnel()
    }

    // MARK: Steps

    private func performConnect() async throws {
        // Validate before touching the system (no extension activation, no VPN preferences).
        guard let config = secrets.get(SecretKey.wireguardConfig),
              !config.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VPNError.notConfigured }
        let endpoint = try WireGuardConfigCheck.validate(config)

        try await ensureExtensionActive()
        let m = try await configuredManager(serverAddress: endpoint)
        guard let session = m.connection as? NETunnelProviderSession else { throw VPNError.stopped("not a tunnel provider session") }

        // Let a previous stop finish before starting again.
        var waits = 0
        while session.status == .disconnecting && waits < 20 { waits += 1; try await Task.sleep(for: .milliseconds(250)) }
        switch session.status {
        case .connected: return
        case .connecting, .reasserting: break   // an earlier start is still in progress: just wait for it
        default: try session.startTunnel(options: TunnelConfigHandoff.startOptions(config: config))
        }

        let start = ContinuousClock.now
        var sawActivity = false
        while true {
            let status = session.status
            if status != .disconnected && status != .invalid { sawActivity = true }
            switch Self.progress(status: status, sawActivity: sawActivity, elapsed: ContinuousClock.now - start) {
            case .connected: return
            case .failed: throw VPNError.stopped(await lastDisconnectReason(session))
            case .timedOut: session.stopVPNTunnel(); throw VPNError.timeout
            case .waiting: try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func ensureExtensionActive() async throws {
        let a = activation ?? SystemExtensionActivation(extensionBundleId: extensionBundleId)
        activation = a
        switch await a.current() {
        case .activated: return
        case .needsApproval: throw VPNError.needsApproval
        case .rebootRequired: throw VPNError.rebootRequired
        case .failed(let why): activation = nil; throw VPNError.activationFailed(why)   // submit a fresh request next time
        case .noAnswer: throw VPNError.activationFailed("macOS did not answer the activation request")
        }
    }

    private func loadManager() async throws -> NETunnelProviderManager? {
        try await NETunnelProviderManager.loadAllFromPreferences().first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == extensionBundleId
        }
    }

    /// Creates or updates the VPN configuration. Holds no secrets: the config travels in the start options.
    private func configuredManager(serverAddress: String) async throws -> NETunnelProviderManager {
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
        return m
    }

    private func lastDisconnectReason(_ session: NEVPNConnection) async -> String? {
        await withCheckedContinuation { cont in
            session.fetchLastDisconnectError { cont.resume(returning: $0?.localizedDescription) }
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
