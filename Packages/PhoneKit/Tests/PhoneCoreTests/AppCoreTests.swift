import XCTest
@testable import PhoneCore

actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}
@MainActor func waitUntil(_ cond: @MainActor () -> Bool) async {
    for _ in 0..<1000 { if cond() { return }; await Task.yield() }
}

@MainActor final class FakeSIP: SIPEngine {
    let events: AsyncStream<SIPEvent>
    private let cont: AsyncStream<SIPEvent>.Continuation
    var registerCalls = 0, unregisterCalls = 0
    var registerError: Error?
    var registerGate: Gate?
    var muteCalls: [Bool] = []
    var dialed: [String] = [], hangups: [Int] = [], answered: [Int] = []
    init() { let p = AsyncStream<SIPEvent>.makeStream(); events = p.stream; cont = p.continuation }
    func emit(_ e: SIPEvent) { cont.yield(e) }
    func register(_ config: SIPConfig) async throws { registerCalls += 1; if let g = registerGate { await g.wait() }; if let e = registerError { throw e } }
    func unregister() { unregisterCalls += 1 }
    func dial(_ number: String) throws -> Int { dialed.append(number); return 7 }
    func answer(_ id: Int) { answered.append(id) }
    func hangup(_ id: Int) { hangups.append(id) }
    func setMuted(_ muted: Bool) { muteCalls.append(muted) }
    var dtmfSent: [(digits: String, callId: Int, method: DTMFMethod)] = []
    var dtmfErrors: [DTMFMethod: String] = [:]
    func sendDTMF(_ digits: String, callId: Int, method: DTMFMethod) -> [DTMFOutcome] {
        dtmfSent.append((digits, callId, method))
        return [DTMFOutcome(method: method, error: dtmfErrors[method])]
    }
}
@MainActor final class FakeVPN: VPNControlling {
    var connectCalls = 0, disconnectCalls = 0
    var error: Error?
    func connect() async throws { connectCalls += 1; if let e = error { throw e } }
    func disconnect() async { disconnectCalls += 1 }
}
final class FakeReach: Reachability, @unchecked Sendable {
    private var results: [Bool]
    private(set) var probes = 0
    init(_ results: [Bool]) { self.results = results }
    func isFritzBoxReachable() async -> Bool { probes += 1; return results.count > 1 ? results.removeFirst() : (results.first ?? false) }
}
@MainActor final class FakePower: PowerAssertionControlling {
    var states: [Bool] = []
    func setPreventSleep(_ on: Bool) { states.append(on) }
}
final class FakeBook: PhoneBookService, @unchecked Sendable {
    var contacts: [Contact] = [Contact(id: "0-1", name: "Erika", numbers: [PhoneNumber(number: "030 1234", type: "home")])]
    var fail = false
    var gate: Gate?
    func loadContacts() async throws -> [Contact] { if let g = gate { await g.wait() }; if fail { throw FritzTestError.down }; return contacts }
    func loadCallList() async throws -> [CallRecord] { if fail { throw FritzTestError.down }; return [] }
}
final class FakeCache: ContactCache, @unchecked Sendable {
    var stored: [Contact] = []
    func load() -> [Contact] { stored }
    func save(_ c: [Contact]) { stored = c }
}
enum FritzTestError: Error { case down }
final class DelayLog: @unchecked Sendable { var values: [TimeInterval] = [] }

@MainActor struct Rig {
    let core: AppCore; let sip: FakeSIP; let vpn: FakeVPN; let power: FakePower
    let reach: FakeReach; let book: FakeBook; let cache: FakeCache; let delays: DelayLog
}

@MainActor func makeRig(reach: [Bool], configured: Bool = true, cached: [Contact] = []) -> Rig {
    let sip = FakeSIP(), vpn = FakeVPN(), power = FakePower(), r = FakeReach(reach), book = FakeBook(), cache = FakeCache(), log = DelayLog()
    cache.stored = cached
    let core = AppCore(sip: sip, phoneBook: book, vpn: vpn, reachability: r, power: power, cache: cache,
                       settings: AppSettings(),
                       sipConfig: { configured ? SIPConfig(host: "fritz.box", user: "u", password: "p") : nil },
                       sleep: { log.values.append($0); await Task.yield() })
    return Rig(core: core, sip: sip, vpn: vpn, power: power, reach: r, book: book, cache: cache, delays: log)
}

@MainActor final class AppCoreTests: XCTestCase {
    func testReachableRegistersWithoutVPN() async {
        let r = makeRig(reach: [true])
        await r.core.start()
        XCTAssertEqual(r.core.connection, .ready)
        XCTAssertEqual(r.vpn.connectCalls, 0)
        XCTAssertEqual(r.sip.registerCalls, 1)
        XCTAssertEqual(r.core.contacts.map(\.name), ["Erika"])
    }
    func testUnreachableStartsVPNThenReady() async {
        let r = makeRig(reach: [false, true])
        await r.core.start()
        XCTAssertEqual(r.vpn.connectCalls, 1)
        XCTAssertEqual(r.core.connection, .ready)
    }
    func testVPNFailureGoesOffline() async {
        let r = makeRig(reach: [false]); r.vpn.error = FritzTestError.down
        await r.core.start()
        guard case .offline = r.core.connection else { return XCTFail("expected offline, got \(r.core.connection)") }
        XCTAssertEqual(r.sip.registerCalls, 0)
    }
    func testStillUnreachableAfterVPNGoesOffline() async {
        let r = makeRig(reach: [false, false])
        await r.core.start()
        guard case .offline = r.core.connection else { return XCTFail("expected offline") }
    }
    func testAuthFailureIsTerminalButPhoneBookStillLoads() async {
        let r = makeRig(reach: [true]); r.sip.registerError = SIPError.authFailed
        await r.core.start()
        XCTAssertEqual(r.core.connection, .authFailed)
        XCTAssertEqual(r.core.contacts.count, 1)
        XCTAssertEqual(r.sip.registerCalls, 1)
    }
    func testPhoneBookFailureFallsBackToCacheWithNotice() async {
        let r = makeRig(reach: [true]); r.book.fail = true
        r.cache.stored = [Contact(id: "c", name: "Cached", numbers: [])]
        await r.core.start()
        XCTAssertEqual(r.core.contacts.map(\.name), ["Cached"])
        XCTAssertNotNil(r.core.phoneBookNotice)
        XCTAssertEqual(r.core.connection, .ready)
    }
    func testPhoneBookFailureNoticeAppendsTransportDetail() async {
        let sip = FakeSIP(), book = FakeBook(), cache = FakeCache()
        book.fail = true
        let core = AppCore(sip: sip, phoneBook: book, vpn: FakeVPN(), reachability: FakeReach([true]), power: FakePower(),
                           cache: cache, settings: AppSettings(),
                           sipConfig: { SIPConfig(host: "fritz.box", user: "u", password: "p") },
                           phoneBookFailureDetail: { "HTTP 401 after Digest challenge, credentials offered" },
                           sleep: { _ in await Task.yield() })
        await core.refreshPhoneBook()
        let notice = try? XCTUnwrap(core.phoneBookNotice)
        XCTAssertTrue(notice?.hasPrefix("Phone book unavailable (") ?? false)
        XCTAssertTrue(notice?.hasSuffix("; showing saved copy. (HTTP 401 after Digest challenge, credentials offered)") ?? false, notice ?? "")
    }
    func testIncomingCallResolvesNameFromPhoneBook() async {
        let r = makeRig(reach: [true])
        await r.core.start()
        r.core.handle(.incomingCall(id: 3, remote: "+49301234", called: nil))
        XCTAssertEqual(r.core.activeCall?.displayName, "Erika")
        XCTAssertEqual(r.core.activeCall?.isIncoming, true)
    }
    func testCalledNumberFlowsIntoActiveCall() async {
        let r = makeRig(reach: [true])
        await r.core.start()
        r.core.handle(.incomingCall(id: 4, remote: "+49301234", called: "5551234"))
        XCTAssertEqual(r.core.activeCall?.calledNumber, "5551234")
    }
    func testDialSetsActiveCallAndEndedClearsIt() async {
        let r = makeRig(reach: [true])
        await r.core.start()
        r.core.dial("030 1234")
        XCTAssertEqual(r.sip.dialed, ["0301234"])
        XCTAssertEqual(r.core.activeCall?.state, .calling)
        r.core.handle(.callState(id: 7, .ended(code: 200, reason: "OK")))
        await r.core.waitForCallCleanup()
        XCTAssertNil(r.core.activeCall)
    }
    func testShutdownStopsVPNOnlyIfStartedByApp() async {
        let a = makeRig(reach: [true]); await a.core.start(); await a.core.shutdown()
        XCTAssertEqual(a.vpn.disconnectCalls, 0)
        let b = makeRig(reach: [false, true]); await b.core.start(); await b.core.shutdown()
        XCTAssertEqual(b.vpn.disconnectCalls, 1)
        XCTAssertEqual(b.sip.unregisterCalls, 1)
    }
    func testKeepAwakeOnlyOnACWhenEnabled() async {
        let r = makeRig(reach: [true])
        r.core.powerSourceChanged(onAC: true);  XCTAssertEqual(r.power.states.last, true)
        r.core.powerSourceChanged(onAC: false); XCTAssertEqual(r.power.states.last, false)
        var s = AppSettings(); s.keepAwakeOnPower = false
        r.core.powerSourceChanged(onAC: true); r.core.updateSettings(s)
        XCTAssertEqual(r.power.states.last, false)
    }
    func testRegistrationLossBacksOffThenRecovers() async {
        let r = makeRig(reach: [true, false, false, true])   // start ok; then 2 failed probes, then ok
        await r.core.start()
        r.core.handle(.registration(.failed(code: 408, reason: "timeout")))
        XCTAssertEqual(r.core.connection, .reconnecting)
        await r.core.waitForReconnect()
        XCTAssertEqual(r.delays.values, [2, 4, 8])
        XCTAssertEqual(r.core.connection, .ready)
        XCTAssertEqual(r.sip.registerCalls, 2)
    }
    func testRegistrationRejectedEventIsAuthFailureWithoutRetry() async {
        let r = makeRig(reach: [true])
        await r.core.start()
        r.core.handle(.registration(.failed(code: 403, reason: "Forbidden")))
        XCTAssertEqual(r.core.connection, .authFailed)
        XCTAssertTrue(r.delays.values.isEmpty)
    }
    func testWakeReprobesAndReRegisters() async {
        let r = makeRig(reach: [true])
        await r.core.start()
        await r.core.handleWake()
        XCTAssertEqual(r.reach.probes, 2)
        XCTAssertEqual(r.sip.registerCalls, 2)
    }

    // MARK: Fix round 1

    func testWakeDuringReconnectCancelsOldLoop() async {                       // finding 1
        let r = makeRig(reach: [true])
        await r.core.start()
        r.core.handle(.registration(.failed(code: 408, reason: "timeout")))
        await r.core.handleWake()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(r.core.connection, .ready)
        XCTAssertEqual(r.sip.registerCalls, 2)       // start + wake only; the old loop never registered
        XCTAssertTrue(r.delays.values.isEmpty)
    }
    func testConcurrentStartsShareOneConnectAttempt() async {                  // finding 2
        let r = makeRig(reach: [false, true])
        async let a: Void = r.core.start()
        async let b: Void = r.core.start()
        _ = await (a, b)
        XCTAssertEqual(r.vpn.connectCalls, 1)
        XCTAssertEqual(r.sip.registerCalls, 1)
        XCTAssertEqual(r.core.connection, .ready)
    }
    func testWakeWhileReadyDoesNotDropToStarting() async {                     // finding 2
        let r = makeRig(reach: [true])
        await r.core.start()
        r.sip.registerGate = Gate()
        let t = Task { await r.core.handleWake() }
        await waitUntil { r.sip.registerCalls == 2 }
        XCTAssertEqual(r.core.connection, .ready)
        await r.sip.registerGate?.release()
        await t.value
        XCTAssertEqual(r.core.connection, .ready)
    }
    func testAuthFailureEventCancelsReconnectLoop() async {                    // finding 3
        let r = makeRig(reach: [true])
        await r.core.start()
        r.core.handle(.registration(.failed(code: 408, reason: "timeout")))
        r.core.handle(.registration(.failed(code: 403, reason: "Forbidden")))
        await r.core.waitForReconnect()
        XCTAssertEqual(r.core.connection, .authFailed)
        XCTAssertTrue(r.delays.values.isEmpty)
        r.core.handle(.registration(.registered))
        XCTAssertEqual(r.core.connection, .authFailed)   // not resurrected by a bare event
    }
    func testRegisteredEventStopsReconnectLoop() async {                       // finding 3
        let r = makeRig(reach: [true])
        await r.core.start()
        r.core.handle(.registration(.failed(code: 408, reason: "timeout")))
        r.core.handle(.registration(.registered))
        await r.core.waitForReconnect()
        XCTAssertEqual(r.core.connection, .ready)
        XCTAssertTrue(r.delays.values.isEmpty)
        XCTAssertEqual(r.sip.registerCalls, 1)
    }
    func testReconnectRestartsVPNWhenTunnelDropped() async {                   // finding 4
        let r = makeRig(reach: [true, false, true])
        await r.core.start()
        r.core.handle(.registration(.failed(code: 408, reason: "timeout")))
        await r.core.waitForReconnect()
        XCTAssertEqual(r.vpn.connectCalls, 1)
        XCTAssertEqual(r.core.connection, .ready)
        await r.core.shutdown()
        XCTAssertEqual(r.vpn.disconnectCalls, 1)
    }
    func testTransientRegisterFailureEntersBackoffThenRecovers() async {       // finding 5
        let r = makeRig(reach: [true])
        r.sip.registerError = SIPError.timeout
        await r.core.start()
        XCTAssertEqual(r.core.connection, .reconnecting)
        r.sip.registerError = nil
        await r.core.waitForReconnect()
        XCTAssertEqual(r.core.connection, .ready)
        XCTAssertEqual(r.delays.values.first, 2)   // loop may retry once before the error is cleared
    }
    func testWakeVPNFailureEntersBackoffAndRetryStillWorks() async {           // finding 5
        let r = makeRig(reach: [true, false, true])
        await r.core.start()
        r.vpn.error = FritzTestError.down
        await r.core.handleWake()
        XCTAssertEqual(r.core.connection, .reconnecting)
        r.vpn.error = nil
        await r.core.retry()
        XCTAssertEqual(r.core.connection, .ready)
        await r.core.shutdown()
    }
    func testEventsFlowThroughRealLoop() async {                               // finding 6
        let r = makeRig(reach: [true])
        await r.core.start()
        r.sip.emit(.incomingCall(id: 3, remote: "+49301234", called: nil))
        await waitUntil { r.core.activeCall != nil }
        XCTAssertEqual(r.core.activeCall?.displayName, "Erika")
    }
    func testEventLoopRunsEvenWhenOffline() async {                            // finding 6
        let r = makeRig(reach: [false]); r.vpn.error = FritzTestError.down
        await r.core.start()
        r.sip.emit(.incomingCall(id: 3, remote: "+49301234", called: nil))
        await waitUntil { r.core.activeCall != nil }
        XCTAssertNotNil(r.core.activeCall)
    }
    func testSecondIncomingCallIsRejectedAndFirstKept() async {                // finding 7
        let r = makeRig(reach: [true])
        await r.core.start()
        r.core.dial("030 1234")
        r.core.handle(.incomingCall(id: 9, remote: "123", called: nil))
        XCTAssertEqual(r.sip.hangups, [9])
        XCTAssertEqual(r.core.activeCall?.id, 7)
    }
    func testStaleCleanupDoesNotClearReusedCallIdAndDialProceedsAfterEnd() async {   // finding 8
        let r = makeRig(reach: [true])
        await r.core.start()
        r.core.dial("030 1234")
        r.core.handle(.callState(id: 7, .ended(code: 200, reason: "OK")))
        r.core.dial("030 1234")                       // allowed: previous call already ended; same id 7 reused
        XCTAssertEqual(r.sip.dialed.count, 2)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(r.core.activeCall?.state, .calling)
    }
    func testShutdownCancelsCleanupAndHangsUpAndReleasesPower() async {        // finding 8 + extras
        let r = makeRig(reach: [true])
        await r.core.start()
        r.core.dial("030 1234")
        await r.core.shutdown()
        XCTAssertEqual(r.sip.hangups, [7])
        XCTAssertEqual(r.power.states.last, false)
        r.core.handle(.callState(id: 7, .ended(code: 200, reason: "OK")))
        await r.core.shutdown()
    }
    func testDialExplainsWhyItFailed() async {                                 // finding 9
        let r = makeRig(reach: [true])
        r.core.dial("1")
        XCTAssertEqual(r.core.lastError, "Not connected")
        await r.core.start()
        r.core.dial("030 1234"); r.core.clearError()
        r.core.dial("2")
        XCTAssertEqual(r.core.lastError, "Already in a call")
    }
    private func ready() async -> Rig { let r = makeRig(reach: [true]); await r.core.start(); return r }
    func testLocalHangupOfConnectedCallSaysCallEnded() async {
        let r = await ready()
        r.core.dial("030 1234")
        r.core.handle(.callState(id: 7, .connected))
        r.core.hangup()
        r.core.handle(.callState(id: 7, .ended(code: 603, reason: "Decline")))
        XCTAssertEqual(r.core.activeCall?.endMessage, "Call ended")
        XCTAssertNil(r.core.lastError)
    }
    func testRemoteEndOfConnectedCallSaysByOtherParty() async {
        let r = await ready()
        r.core.dial("030 1234")
        r.core.handle(.callState(id: 7, .connected))
        r.core.handle(.callState(id: 7, .ended(code: 200, reason: "OK")))
        XCTAssertEqual(r.core.activeCall?.endMessage, "Call ended by the other party")
        XCTAssertNil(r.core.lastError)
    }
    func testLocalDeclineOfRingingIncomingCall() async {
        let r = await ready()
        r.core.handle(.incomingCall(id: 3, remote: "123", called: nil))
        r.core.hangup()
        r.core.handle(.callState(id: 3, .ended(code: 603, reason: "Decline")))
        XCTAssertEqual(r.core.activeCall?.endMessage, "Call declined")
        XCTAssertNil(r.core.lastError)
    }
    func testRemoteCancelOfRingingIncomingCallIsMissed() async {
        let r = await ready()
        r.core.handle(.incomingCall(id: 3, remote: "123", called: nil))
        r.core.handle(.callState(id: 3, .ended(code: 487, reason: "Request Terminated")))
        XCTAssertEqual(r.core.activeCall?.endMessage, "Missed call")
        XCTAssertNil(r.core.lastError)
    }
    func testOutgoingBusyIsNotAnError() async {
        let r = await ready()
        r.core.dial("030 1234")
        r.core.handle(.callState(id: 7, .ended(code: 486, reason: "Busy Here")))
        XCTAssertEqual(r.core.activeCall?.endMessage, "Busy")
        XCTAssertNil(r.core.lastError)
    }
    func testLocalCancelOfOutgoingCall() async {
        let r = await ready()
        r.core.dial("030 1234")
        r.core.hangup()
        r.core.handle(.callState(id: 7, .ended(code: 487, reason: "Cancelled")))
        XCTAssertEqual(r.core.activeCall?.endMessage, "Call cancelled")
        XCTAssertNil(r.core.lastError)
    }
    func testUnknownFailureSetsError() async {
        let r = await ready()
        r.core.dial("030 1234")
        r.core.handle(.callState(id: 7, .ended(code: 500, reason: "Server Error")))
        XCTAssertEqual(r.core.activeCall?.endMessage, "Call failed: 500 Server Error")
        XCTAssertEqual(r.core.lastError, "Call failed: 500 Server Error")
    }
    func testEndedLocallyFlagResetsForNextCall() async {
        let r = await ready()
        r.core.dial("030 1234")
        r.core.hangup()
        r.core.handle(.callState(id: 7, .ended(code: 487, reason: "Cancelled")))
        r.core.dial("030 1234")
        r.core.handle(.callState(id: 7, .connected))
        r.core.handle(.callState(id: 7, .ended(code: 200, reason: "OK")))
        XCTAssertEqual(r.core.activeCall?.endMessage, "Call ended by the other party")
    }
    func testSlowPhoneBookDoesNotDelayRegistration() async {                   // finding 10
        let r = makeRig(reach: [true])
        r.book.gate = Gate()
        let t = Task { await r.core.start() }
        await waitUntil { r.core.connection == .ready }
        XCTAssertEqual(r.core.connection, .ready)
        XCTAssertEqual(r.sip.registerCalls, 1)
        XCTAssertTrue(r.core.contacts.isEmpty)
        await r.book.gate?.release()
        await t.value
        XCTAssertEqual(r.core.contacts.map(\.name), ["Erika"])
    }
    func testContactsSeededFromCacheAtInit() {
        let r = makeRig(reach: [true], cached: [Contact(id: "c", name: "Cached", numbers: [])])
        XCTAssertEqual(r.core.contacts.map(\.name), ["Cached"])
    }
    func testMuteResetsWhenNewCallStarts() async {
        let r = makeRig(reach: [true])
        await r.core.start()
        r.core.dial("030 1234"); r.core.toggleMute()
        r.core.handle(.callState(id: 7, .ended(code: 200, reason: "OK")))
        r.core.dial("030 1234")
        XCTAssertEqual(r.sip.muteCalls.last, false)
        XCTAssertEqual(r.core.activeCall?.muted, false)
    }
    func testPartiallyStartedVPNIsTornDownOnShutdown() async {
        let r = makeRig(reach: [false]); r.vpn.error = FritzTestError.down
        await r.core.start()
        await r.core.shutdown()
        XCTAssertEqual(r.vpn.disconnectCalls, 1)
    }
    func testDialRejectsInvalidNumbersWithoutDialling() async {               // I1
        let r = makeRig(reach: [true])
        await r.core.start()
        for bad in ["x@evil.example;transport=tcp", "", "030\n1234", "sip:1@host"] {
            r.core.clearError()
            r.core.dial(bad)
            XCTAssertEqual(r.core.lastError, "Invalid number", bad)
        }
        XCTAssertTrue(r.sip.dialed.isEmpty)
        XCTAssertNil(r.core.activeCall)
        r.core.clearError()
        r.core.dial("+49 (0)30 1234")
        XCTAssertEqual(r.sip.dialed, ["+49301234"])
        XCTAssertEqual(r.core.activeCall?.displayName, "Erika")
        XCTAssertNil(r.core.lastError)
    }
    // MARK: Final review fixes

    func testWakeDuringConnectedCallKeepsCallAndDefersReRegister() async {   // C1
        let r = makeRig(reach: [true])
        await r.core.start()
        r.core.handle(.incomingCall(id: 3, remote: "+49301234", called: nil))
        r.core.handle(.callState(id: 3, .connected))
        await r.core.handleWake()             // network-path change and wake both arrive here
        await r.core.handleWake()
        XCTAssertEqual(r.sip.registerCalls, 1)
        XCTAssertEqual(r.reach.probes, 1)
        XCTAssertEqual(r.core.activeCall?.id, 3)
        XCTAssertEqual(r.core.activeCall?.state, .connected)
        XCTAssertTrue(r.sip.hangups.isEmpty)
        XCTAssertEqual(r.core.connection, .ready)
        r.core.handle(.callState(id: 3, .ended(code: 200, reason: "OK")))
        await waitUntil { r.sip.registerCalls == 2 }
        XCTAssertEqual(r.sip.registerCalls, 2)   // exactly one deferred re-register
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(r.sip.registerCalls, 2)
        XCTAssertEqual(r.core.connection, .ready)
    }
    func testSettingsSaveDuringCallIsDeferredUntilCallEnds() async {          // C1
        let r = makeRig(reach: [true])
        await r.core.start()
        r.core.dial("030 1234")
        r.core.handle(.callState(id: 7, .connected))
        await r.core.retry()                  // AppEnvironment.applySettings -> core.retry()
        XCTAssertEqual(r.sip.registerCalls, 1)
        XCTAssertEqual(r.core.activeCall?.state, .connected)
        r.core.handle(.callState(id: 7, .ended(code: 200, reason: "OK")))
        await waitUntil { r.sip.registerCalls == 2 }
        XCTAssertEqual(r.sip.registerCalls, 2)
    }
    func testCallEndWithoutDeferredRequestDoesNotReRegister() async {         // C1
        let r = makeRig(reach: [true])
        await r.core.start()
        r.core.dial("030 1234")
        r.core.handle(.callState(id: 7, .ended(code: 200, reason: "OK")))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(r.sip.registerCalls, 1)
    }
    func testReconnectRestartsAppStartedTunnel() async {                      // I6
        let r = makeRig(reach: [false, true, false, true])   // away: VPN up; later unreachable again, then ok
        await r.core.start()
        XCTAssertEqual(r.vpn.connectCalls, 1)
        r.core.handle(.registration(.failed(code: 408, reason: "timeout")))
        await r.core.waitForReconnect()
        XCTAssertEqual(r.vpn.disconnectCalls, 1)   // restarted, not "connect" on a tunnel that reports connected
        XCTAssertEqual(r.vpn.connectCalls, 2)
        XCTAssertEqual(r.core.connection, .ready)
    }
    func testReconnectSurfacesVPNErrorAndKeepsBackingOff() async {            // I6
        let r = makeRig(reach: [false, true, false, false, true])
        await r.core.start()
        r.vpn.error = FritzTestError.down
        r.core.handle(.registration(.failed(code: 408, reason: "timeout")))
        await waitUntil { r.core.lastError != nil }
        XCTAssertEqual(r.core.lastError?.hasPrefix("VPN: "), true)
        await r.core.waitForReconnect()
        XCTAssertEqual(r.delays.values, [2, 4, 8])
        XCTAssertEqual(r.core.connection, .ready)
        XCTAssertNil(r.core.lastError)             // cleared once the connection recovered
    }
    func testVPNCancellationIsNotReportedAsError() async {                   // I6
        let r = makeRig(reach: [false, true, false, true])
        await r.core.start()
        r.vpn.error = CancellationError()
        r.core.handle(.registration(.failed(code: 408, reason: "timeout")))
        await r.core.waitForReconnect()
        XCTAssertNil(r.core.lastError)
        XCTAssertEqual(r.core.connection, .ready)
        let s = makeRig(reach: [false]); s.vpn.error = CancellationError()
        await s.core.start()
        XCTAssertNil(s.core.lastError)
        if case .offline(let m) = s.core.connection { XCTAssertFalse(m.hasPrefix("VPN"), m) }
    }
    func testHangingPhoneBookDoesNotBlockWake() async {                       // I7
        let r = makeRig(reach: [true])
        r.book.gate = Gate()
        let t = Task { await r.core.start() }
        await waitUntil { r.core.connection == .ready }
        await r.core.handleWake()             // must not join a connect attempt held by the phone book
        XCTAssertEqual(r.sip.registerCalls, 2)
        await r.book.gate?.release()
        await t.value
        XCTAssertEqual(r.core.contacts.map(\.name), ["Erika"])
    }
    func testShutdownThenStartKeepsNewConnectTask() async {                   // I7
        let r = makeRig(reach: [true])
        let g1 = Gate(); r.sip.registerGate = g1
        let a = Task { await r.core.start() }
        await waitUntil { r.sip.registerCalls == 1 }
        await r.core.shutdown()
        let g2 = Gate(); r.sip.registerGate = g2
        let b = Task { await r.core.start() }
        await waitUntil { r.sip.registerCalls == 2 }
        await g1.release()
        await a.value                         // the old attempt finishes after the new one started
        let c = Task { await r.core.retry() } // must join the new attempt, not start a third
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(r.sip.registerCalls, 2)
        await g2.release()
        await b.value; await c.value
        XCTAssertEqual(r.sip.registerCalls, 2)
        XCTAssertEqual(r.core.connection, .ready)
    }
    func testSIPConfigDescriptionRedactsPassword() {
        let c = SIPConfig(host: "h", user: "u", password: "s3cret")
        XCTAssertFalse("\(c)".contains("s3cret"))
        XCTAssertFalse(String(reflecting: c).contains("s3cret"))
    }
}
