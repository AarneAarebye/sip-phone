// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 SIP Phone contributors

import XCTest
import NetworkExtension
import SystemExtensions
import PhoneCore
@testable import VPN

/// Dummy keys only (all-zero / all-0x01 32-byte values): never a real WireGuard config.
private let zeroKey = Data(count: 32).base64EncodedString()
private let onesKey = Data(repeating: 1, count: 32).base64EncodedString()
private let dummyConfig = """
[Interface]
PrivateKey = \(zeroKey)
Address = 192.168.178.201/24
DNS = 192.168.178.1

# a comment
[Peer]
PublicKey = \(onesKey)
PresharedKey = \(zeroKey)
AllowedIPs = 0.0.0.0/0
Endpoint = example.invalid:51820
PersistentKeepalive = 25
"""

private final class FakeSecrets: SecretStore, @unchecked Sendable {
    var values: [String: String] = [:]
    func get(_ key: String) -> String? { values[key] }
    func contains(_ key: String) -> Bool { values[key] != nil }
    func set(_ value: String?, for key: String) throws { values[key] = value }
}

final class WireGuardConfigCheckTests: XCTestCase {
    func testValidConfigReturnsEndpoint() throws {
        XCTAssertEqual(try WireGuardConfigCheck.validate(dummyConfig), "example.invalid:51820")
    }

    func testRejectsBrokenConfigsWithoutLeakingValues() {
        let cases: [(String, String)] = [
            ("", "[Interface]"),
            ("hello", "unexpected line"),
            (dummyConfig.replacingOccurrences(of: "PrivateKey = \(zeroKey)", with: "PrivateKey = c2VjcmV0"), "PrivateKey"),
            (dummyConfig.replacingOccurrences(of: "Address = 192.168.178.201/24", with: ""), "Address"),
            (dummyConfig.replacingOccurrences(of: "PublicKey = \(onesKey)", with: "PublicKey = x"), "PublicKey"),
            (dummyConfig.replacingOccurrences(of: "Endpoint = example.invalid:51820", with: ""), "Endpoint"),
            (String(dummyConfig.prefix(while: { $0 != "#" })), "[Peer]"),
            (dummyConfig + "\n[Interface]\nPrivateKey = \(zeroKey)\n", "exactly one"),
        ]
        for (text, expected) in cases {
            XCTAssertThrowsError(try WireGuardConfigCheck.validate(text)) { error in
                guard case VPNError.invalidConfig(let why) = error else { return XCTFail("\(error)") }
                XCTAssertTrue(why.contains(expected), "\(why) should mention \(expected)")
                let description = error.localizedDescription
                XCTAssertFalse(description.contains(zeroKey) || description.contains("c2VjcmV0"), "description leaks a key")
            }
        }
    }
}

final class TunnelConfigHandoffTests: XCTestCase {
    func testRoundTrip() {
        XCTAssertEqual(TunnelConfigHandoff.config(fromStartOptions: TunnelConfigHandoff.startOptions(config: dummyConfig)), dummyConfig)
    }
    func testMissingOrEmptyOptions() {
        XCTAssertNil(TunnelConfigHandoff.config(fromStartOptions: nil))
        XCTAssertNil(TunnelConfigHandoff.config(fromStartOptions: [:]))
        XCTAssertNil(TunnelConfigHandoff.config(fromStartOptions: TunnelConfigHandoff.startOptions(config: "")))
    }
}

final class VPNStatusMappingTests: XCTestCase {
    func testProgress() {
        let p = VPNManager.progress
        XCTAssertEqual(p(.connected, false, .zero), .connected)
        XCTAssertEqual(p(.connecting, true, .seconds(1)), .waiting)
        XCTAssertEqual(p(.reasserting, true, .seconds(1)), .waiting)
        XCTAssertEqual(p(.disconnecting, true, .seconds(1)), .waiting)
        // just after startTunnel the status may still read disconnected: grace period
        XCTAssertEqual(p(.disconnected, false, .milliseconds(250)), .waiting)
        XCTAssertEqual(p(.disconnected, false, .seconds(3)), .failed)
        XCTAssertEqual(p(.disconnected, true, .milliseconds(500)), .failed)
        XCTAssertEqual(p(.invalid, true, .milliseconds(500)), .failed)
        XCTAssertEqual(p(.connecting, true, .seconds(20)), .timedOut)
    }

    func testActivationErrorMessages() {
        let err = NSError(domain: OSSystemExtensionErrorDomain, code: OSSystemExtensionError.Code.unsupportedParentBundleLocation.rawValue)
        XCTAssertTrue(SystemExtensionActivation.message(for: err).contains("Applications"))
    }

    func testErrorDescriptions() {
        XCTAssertTrue(VPNError.needsApproval.localizedDescription
            .contains("System Settings > General > Login Items & Extensions > Network Extensions"))
        XCTAssertEqual(VPNError.stopped(nil).localizedDescription, "VPN stopped unexpectedly")
        XCTAssertEqual(VPNError.stopped("no config").localizedDescription, "VPN stopped: no config")
    }
}

final class SystemExtensionActivationTests: XCTestCase {
    private func make() -> (SystemExtensionActivation, OSSystemExtensionRequest) {
        var submitted: OSSystemExtensionRequest?
        let a = SystemExtensionActivation(extensionBundleId: "invalid.test", submit: { submitted = $0 })
        return (a, submitted!)
    }

    func testApprovalThenCompletionKeepsLatestOutcome() async {
        let (a, req) = make()
        async let first = a.current()
        try? await Task.sleep(for: .milliseconds(50))
        a.requestNeedsUserApproval(req)
        let firstOutcome = await first
        XCTAssertEqual(firstOutcome, .needsApproval)
        let second = await a.current()
        XCTAssertEqual(second, .needsApproval)
        a.request(req, didFinishWithResult: .completed)   // late completion: no waiter, no double resume
        a.request(req, didFinishWithResult: .completed)
        let third = await a.current()
        XCTAssertEqual(third, .activated)
    }

    func testSeveralWaitersResumedOnceAndTimeout() async {
        let (a, req) = make()
        async let w1 = a.current()
        async let w2 = a.current()
        try? await Task.sleep(for: .milliseconds(50))
        a.request(req, didFailWithError: NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"]))
        let r = await [w1, w2]
        XCTAssertEqual(r, [.failed("boom"), .failed("boom")])

        let (b, _) = make()
        let timedOut = await b.current(timeout: 0.05)
        XCTAssertEqual(timedOut, .noAnswer)
    }

    func testWaitEndsWhenCallerIsCancelled() async {
        let (a, _) = make()
        let waiting = Task { await a.current(timeout: 30) }
        try? await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        let outcome = await waiting.value
        XCTAssertEqual(outcome, .noAnswer)
    }

    func testResultMapping() {
        XCTAssertEqual(SystemExtensionActivation.outcome(for: .completed), .activated)
        XCTAssertEqual(SystemExtensionActivation.outcome(for: .willCompleteAfterReboot), .rebootRequired)
    }
}

@MainActor
final class VPNManagerValidationTests: XCTestCase {
    // These fail before any system call (no extension activation, no VPN preferences).
    func testMissingConfig() async {
        let vpn = VPNManager(secrets: FakeSecrets(), extensionBundleId: "invalid.test")
        await assertThrows(VPNError.notConfigured) { try await vpn.connect() }
    }
    func testBlankConfig() async {
        let s = FakeSecrets(); s.values[SecretKey.wireguardConfig] = "  \n"
        await assertThrows(VPNError.notConfigured) { try await VPNManager(secrets: s, extensionBundleId: "invalid.test").connect() }
    }
    func testInvalidConfig() async {
        let s = FakeSecrets(); s.values[SecretKey.wireguardConfig] = "[Interface]\nAddress = 10.0.0.2/32\n"
        do { try await VPNManager(secrets: s, extensionBundleId: "invalid.test").connect(); XCTFail("expected error") }
        catch { guard case VPNError.invalidConfig = error else { return XCTFail("\(error)") } }
    }

    private func assertThrows(_ expected: VPNError, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("expected \(expected)") }
        catch { XCTAssertEqual(error as? VPNError, expected) }
    }
}

/// Records calls; activation is held until `releaseActivation` (cancellable, like the real one).
@MainActor
private final class FakeBackend: TunnelBackend {
    var activations = 0, starts = 0, stops = 0
    var activationReleased = false
    var connectOnStart = true
    var status: NEVPNStatus = .disconnected

    func activateExtension() async throws {
        activations += 1
        while !activationReleased { try await Task.sleep(for: .milliseconds(5)) }
    }
    func configure(serverAddress: String) async throws {}
    func start(options: [String: NSObject]) throws {
        XCTAssertNotNil(TunnelConfigHandoff.config(fromStartOptions: options))
        starts += 1
        status = connectOnStart ? .connected : .connecting
    }
    func stop() async { stops += 1; status = .disconnected }
    func lastDisconnectReason() async -> String? { nil }
}

@MainActor
final class VPNManagerConcurrencyTests: XCTestCase {
    private func makeManager() -> (VPNManager, FakeBackend) {
        let s = FakeSecrets(); s.values[SecretKey.wireguardConfig] = dummyConfig
        let backend = FakeBackend()
        return (VPNManager(secrets: s, backend: backend), backend)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "condition not reached", file: file, line: line)
    }

    func testRepeatedConnectCallsShareOneAttempt() async throws {
        let (vpn, backend) = makeManager()
        async let a: Void = vpn.connect()
        async let b: Void = vpn.connect()
        await waitUntil { backend.activations == 1 }
        backend.activationReleased = true
        _ = try await (a, b)
        XCTAssertEqual(backend.activations, 1)
        XCTAssertEqual(backend.starts, 1)
        try await vpn.connect()                       // already connected: no new start
        XCTAssertEqual(backend.starts, 1)
    }

    func testCancelledJoinerDoesNotCancelSharedAttempt() async throws {
        let (vpn, backend) = makeManager()
        let first = Task { try await vpn.connect() }
        let second = Task { try await vpn.connect() }
        await waitUntil { backend.activations == 1 }
        second.cancel()
        do { try await second.value; XCTFail("cancelled caller should throw") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        backend.activationReleased = true
        try await first.value                          // the shared attempt kept going
        XCTAssertEqual(backend.starts, 1)
        XCTAssertEqual(backend.status, .connected)
    }

    func testDisconnectDuringActivationPreventsStart() async throws {
        let (vpn, backend) = makeManager()
        let connecting = Task { try await vpn.connect() }
        await waitUntil { backend.activations == 1 }
        await vpn.disconnect()
        backend.activationReleased = true              // even if the system answers later
        do { try await connecting.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(backend.starts, 0)
        XCTAssertEqual(backend.stops, 1)
    }

    func testDisconnectAfterStartStopsTunnel() async throws {
        let (vpn, backend) = makeManager()
        backend.activationReleased = true
        backend.connectOnStart = false                 // stays .connecting
        let connecting = Task { try await vpn.connect() }
        await waitUntil { backend.starts == 1 }
        await vpn.disconnect()
        XCTAssertEqual(backend.stops, 1)
        XCTAssertEqual(backend.status, .disconnected)
        do { try await connecting.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(backend.starts, 1)
    }
}
