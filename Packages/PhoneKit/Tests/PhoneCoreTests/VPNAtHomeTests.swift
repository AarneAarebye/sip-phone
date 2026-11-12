// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import XCTest
@testable import PhoneCore

/// Fake clock for the home check: the periodic interval suspends until `tick()` (or cancellation); any other
/// pause (the confirmation delay) returns at once. Records every requested pause.
final class Ticker: @unchecked Sendable {
    let interval: TimeInterval
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var log: [TimeInterval] = []
    init(interval: TimeInterval) { self.interval = interval }

    var requested: [TimeInterval] { lock.withLock { log } }
    var pending: Int { lock.withLock { waiters.count } }

    func sleep(_ t: TimeInterval) async {
        lock.withLock { log.append(t) }
        guard t == interval else { await Task.yield(); return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.withLock { waiters[id] = c }
                if Task.isCancelled { resume(id) }
            }
        } onCancel: { resume(id) }
    }
    private func resume(_ id: UUID) { lock.withLock { waiters.removeValue(forKey: id) }?.resume() }
    func tick() { let w = lock.withLock { let w = waiters; waiters = [:]; return w }; w.values.forEach { $0.resume() } }
}

@MainActor func eventually(_ cond: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<500 where !cond() { try? await Task.sleep(for: .milliseconds(2)) }
    XCTAssertTrue(cond(), "condition not reached", file: file, line: line)
}

@MainActor struct HomeRig {
    let core: AppCore; let sip: FakeSIP; let vpn: FakeVPN; let reach: FakeReach; let ticker: Ticker
}

@MainActor func makeHomeRig(reach: [Bool], direct: [Bool]) -> HomeRig {
    let sip = FakeSIP(), vpn = FakeVPN(), r = FakeReach(reach)
    r.direct = direct
    let timing = AppCore.HomeCheckTiming(interval: 20, confirmDelay: 3, confirmations: 2)
    let ticker = Ticker(interval: timing.interval)
    let core = AppCore(sip: sip, phoneBook: FakeBook(), vpn: vpn, reachability: r, power: FakePower(), cache: FakeCache(),
                       settings: AppSettings(),
                       sipConfig: { SIPConfig(host: "fritz.box", user: "u", password: "p") },
                       sleep: { _ in await Task.yield() },
                       homeTiming: timing, homeSleep: { await ticker.sleep($0) })
    return HomeRig(core: core, sip: sip, vpn: vpn, reach: r, ticker: ticker)
}

@MainActor final class VPNAtHomeTests: XCTestCase {
    /// Away: the first direct probe (in the connect attempt) fails, so the app starts its tunnel.
    private func awayWithVPN(direct later: [Bool]) async -> HomeRig {
        let r = makeHomeRig(reach: [false, true], direct: [false] + later)
        await r.core.start()
        XCTAssertEqual(r.vpn.connectCalls, 1)
        XCTAssertEqual(r.core.connection, .ready)
        await eventually { r.ticker.pending == 1 }   // periodic check armed
        return r
    }

    func testHomeDetectedStopsAppStartedVPNOnceAndReRegisters() async {
        let r = await awayWithVPN(direct: [true])
        let registers = r.sip.registerCalls, changes = r.sip.networkChanges
        r.ticker.tick()
        await eventually { r.vpn.disconnectCalls == 1 && r.sip.registerCalls == registers + 1 }
        XCTAssertEqual(r.reach.directProbes, 3)                 // connect attempt + two confirmations
        XCTAssertEqual(r.ticker.requested.filter { $0 == 3 }.count, 1)
        XCTAssertEqual(r.core.vpnNotice, AppCore.homeNotice)
        XCTAssertNil(r.core.lastError)
        XCTAssertEqual(r.core.connection, .ready)
        XCTAssertEqual(r.sip.networkChanges, changes + 1)       // transport rebound before re-registering
        XCTAssertEqual(r.vpn.connectCalls, 1)                   // never restarted at home
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(r.ticker.pending, 0)                     // periodic check stopped with the tunnel
        await r.core.handleWake()
        XCTAssertEqual(r.vpn.disconnectCalls, 1)                // stopped exactly once
        await r.core.shutdown()
        XCTAssertEqual(r.vpn.disconnectCalls, 1)                // no longer ours to stop
    }

    func testFlappingDoesNotStopVPN() async {
        let r = await awayWithVPN(direct: [true, false])        // one success, then failures
        r.ticker.tick()
        await eventually { r.reach.directProbes == 3 && r.ticker.pending == 1 }
        XCTAssertEqual(r.vpn.disconnectCalls, 0)
        r.ticker.tick()
        await eventually { r.reach.directProbes == 4 && r.ticker.pending == 1 }   // first probe fails: no confirmation
        XCTAssertEqual(r.vpn.disconnectCalls, 0)
        XCTAssertNil(r.core.vpnNotice)
        await r.core.shutdown()
    }

    func testHomeCheckDuringCallIsDeferredUntilCallEnds() async {
        let r = await awayWithVPN(direct: [true])
        r.core.dial("030 1234")
        r.core.handle(.callState(id: 7, .connected))
        r.ticker.tick()
        await eventually { r.ticker.pending == 1 }
        XCTAssertEqual(r.reach.directProbes, 1)                 // not even probed during the call
        XCTAssertEqual(r.vpn.disconnectCalls, 0)
        await r.core.handleWake()                               // path change during the call: deferred too
        XCTAssertEqual(r.vpn.disconnectCalls, 0)
        XCTAssertEqual(r.core.activeCall?.state, .connected)
        let changes = r.sip.networkChanges
        r.core.handle(.callState(id: 7, .ended(code: 200, reason: "OK")))
        await eventually { r.vpn.disconnectCalls == 1 }
        await eventually { r.sip.networkChanges == changes + 1 }
        XCTAssertEqual(r.core.vpnNotice, AppCore.homeNotice)
        await r.core.shutdown()
    }

    func testUserStartedVPNIsNeverStoppedByTheApp() async {
        // The box answers over the default route (a tunnel the app did not start) and also directly.
        let r = makeHomeRig(reach: [true], direct: [true])
        await r.core.start()
        await r.core.handleWake()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(r.ticker.pending, 0)
        XCTAssertEqual(r.vpn.connectCalls, 0)
        await r.core.shutdown()
        XCTAssertEqual(r.vpn.disconnectCalls, 0)
        XCTAssertNil(r.core.vpnNotice)
    }

    func testShutdownCancelsHomeCheckTimer() async {
        let r = await awayWithVPN(direct: [true])
        await r.core.shutdown()
        XCTAssertEqual(r.vpn.disconnectCalls, 1)                // shutdown stops our tunnel
        await eventually { r.ticker.pending == 0 }              // the sleeping timer was cancelled
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(r.reach.directProbes, 1)                 // and never probed afterwards
        XCTAssertNil(r.core.vpnNotice)
    }

    func testWakeAtHomeStopsVPNWithoutWaitingForTimer() async {
        let r = await awayWithVPN(direct: [true])
        await r.core.handleWake()
        XCTAssertEqual(r.vpn.disconnectCalls, 1)
        XCTAssertEqual(r.core.vpnNotice, AppCore.homeNotice)
        XCTAssertEqual(r.core.connection, .ready)
        await r.core.shutdown()
    }

    func testWakeAwayKeepsVPNAndReRegisters() async {
        let r = await awayWithVPN(direct: [false])
        let registers = r.sip.registerCalls
        await r.core.handleWake()
        XCTAssertEqual(r.vpn.disconnectCalls, 0)
        XCTAssertEqual(r.reach.directProbes, 2)                 // one failed probe ends the check
        XCTAssertEqual(r.sip.registerCalls, registers + 1)
        await r.core.shutdown()
    }

    func testNeverStartsVPNWhenDirectProbeSaysHome() async {
        let r = makeHomeRig(reach: [false, true], direct: [true])
        await r.core.start()
        XCTAssertEqual(r.vpn.connectCalls, 0)
        XCTAssertEqual(r.sip.registerCalls, 1)
        XCTAssertEqual(r.core.connection, .ready)
    }

    func testReconnectAtHomeStopsStaleTunnelInsteadOfRestartingIt() async {
        // Away with our tunnel; later the box is unreachable over the default route but answers directly.
        let r = makeHomeRig(reach: [false, true, false, true], direct: [false, true])
        await r.core.start()
        XCTAssertEqual(r.vpn.connectCalls, 1)
        r.core.handle(.registration(.failed(code: 408, reason: "timeout")))
        await r.core.waitForReconnect()
        XCTAssertEqual(r.vpn.disconnectCalls, 1)
        XCTAssertEqual(r.vpn.connectCalls, 1)                   // not restarted at home
        XCTAssertEqual(r.core.connection, .ready)
        XCTAssertEqual(r.core.vpnNotice, AppCore.homeNotice)
        await r.core.shutdown()
        XCTAssertEqual(r.vpn.disconnectCalls, 1)
    }

    func testVPNStartRebindsTransportBeforeRegistering() async {
        let r = makeHomeRig(reach: [false, true], direct: [false])
        await r.core.start()
        XCTAssertEqual(r.sip.networkChanges, 1)
        XCTAssertEqual(r.sip.registerCalls, 1)
        await r.core.shutdown()
    }

    func testPathChangeRebindsTransportOnceAndDefersDuringCall() async {
        let r = makeRig(reach: [true])
        await r.core.start()
        XCTAssertEqual(r.sip.networkChanges, 0)                 // first start: nothing to rebind
        await r.core.handleWake()
        XCTAssertEqual(r.sip.networkChanges, 1)
        r.core.dial("030 1234")
        r.core.handle(.callState(id: 7, .connected))
        await r.core.handleWake()
        XCTAssertEqual(r.sip.networkChanges, 1)                 // never during a live call
        r.core.handle(.callState(id: 7, .ended(code: 200, reason: "OK")))
        await eventually { r.sip.networkChanges == 2 && r.sip.registerCalls == 3 }
    }

    func testSettingsDefaultsAndTolerantDecoding() throws {
        let d = AppSettings()
        XCTAssertTrue(d.splitTunnel)
        XCTAssertEqual(d.homeNetworkCIDR, "")
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"sipUser":"622"}"#.utf8))
        XCTAssertTrue(old.splitTunnel)
        XCTAssertEqual(old.homeNetworkCIDR, "")
        var s = AppSettings(); s.splitTunnel = false; s.homeNetworkCIDR = "192.168.65.0/24"
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s)), s)
        let bad = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"splitTunnel":"yes","homeNetworkCIDR":5}"#.utf8))
        XCTAssertTrue(bad.splitTunnel)
        XCTAssertEqual(bad.homeNetworkCIDR, "")
    }
}
