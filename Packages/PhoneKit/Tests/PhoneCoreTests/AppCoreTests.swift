import XCTest
@testable import PhoneCore

@MainActor final class FakeSIP: SIPEngine {
    let events: AsyncStream<SIPEvent>
    private let cont: AsyncStream<SIPEvent>.Continuation
    var registerCalls = 0, unregisterCalls = 0
    var registerError: Error?
    var dialed: [String] = [], hangups: [Int] = [], answered: [Int] = []
    init() { let p = AsyncStream<SIPEvent>.makeStream(); events = p.stream; cont = p.continuation }
    func emit(_ e: SIPEvent) { cont.yield(e) }
    func register(_ config: SIPConfig) async throws { registerCalls += 1; if let e = registerError { throw e } }
    func unregister() { unregisterCalls += 1 }
    func dial(_ number: String) throws -> Int { dialed.append(number); return 7 }
    func answer(_ id: Int) { answered.append(id) }
    func hangup(_ id: Int) { hangups.append(id) }
    func setMuted(_ muted: Bool) {}
    func sendDTMF(_ digits: String, callId: Int) {}
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
    func loadContacts() async throws -> [Contact] { if fail { throw FritzTestError.down }; return contacts }
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

@MainActor func makeRig(reach: [Bool], configured: Bool = true) -> Rig {
    let sip = FakeSIP(), vpn = FakeVPN(), power = FakePower(), r = FakeReach(reach), book = FakeBook(), cache = FakeCache(), log = DelayLog()
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
    func testIncomingCallResolvesNameFromPhoneBook() async {
        let r = makeRig(reach: [true])
        await r.core.start()
        r.core.handle(.incomingCall(id: 3, remote: "+49301234"))
        XCTAssertEqual(r.core.activeCall?.displayName, "Erika")
        XCTAssertEqual(r.core.activeCall?.isIncoming, true)
    }
    func testDialSetsActiveCallAndEndedClearsIt() async {
        let r = makeRig(reach: [true])
        await r.core.start()
        r.core.dial("030 1234")
        XCTAssertEqual(r.sip.dialed, ["030 1234"])
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
}
