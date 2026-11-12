import XCTest
@testable import PhoneCore

@MainActor final class DTMFTests: XCTestCase {
    private func connectedRig(method: DTMFMethod = .rfc2833) async -> Rig {
        let r = makeRig(reach: [true])
        await r.core.start()
        if method != .rfc2833 { var s = AppSettings(); s.dtmfMethod = method; r.core.updateSettings(s) }
        r.core.dial("0301234")
        r.core.handle(.callState(id: 7, .connected))
        return r
    }

    func testDefaultSendsRFC2833ToActiveCallAndReportsSuccess() async {
        let r = await connectedRig()
        r.core.sendDTMF("5")
        XCTAssertEqual(r.sip.dtmfSent.count, 1)
        XCTAssertEqual(r.sip.dtmfSent.first?.digits, "5")
        XCTAssertEqual(r.sip.dtmfSent.first?.callId, 7)
        XCTAssertEqual(r.sip.dtmfSent.first?.method, .rfc2833)
        XCTAssertEqual(r.core.activeCall?.dtmfStatus, "Tone sent via RFC 2833")
        XCTAssertEqual(r.core.activeCall?.dtmfSerial, 1)
    }

    func testFailureIsSurfacedWithoutDigits() async {
        let r = await connectedRig()
        r.sip.dtmfErrors[.rfc2833] = "No RFC 2833 support in remote [status 220107]"
        r.core.sendDTMF("1234")
        let status = r.core.activeCall?.dtmfStatus ?? ""
        XCTAssertEqual(status, "4 tones failed (RFC 2833): No RFC 2833 support in remote [status 220107]")
        XCTAssertFalse(status.contains("1234"))
    }

    func testMethodFromSettingsIsPassedPerCall() async {
        let r = await connectedRig(method: .sipInfo)
        r.core.sendDTMF("#")
        XCTAssertEqual(r.sip.dtmfSent.first?.method, .sipInfo)
        XCTAssertEqual(r.core.activeCall?.dtmfStatus, "Tone sent via SIP INFO")
    }

    func testBothReportsEachWireMethod() async {
        let r = await connectedRig(method: .both)
        r.sip.dtmfErrors[.sipInfo] = "Invalid operation [status 70013]"
        r.core.sendDTMF("9")
        XCTAssertEqual(r.core.activeCall?.dtmfStatus,
                       "Tone sent via RFC 2833 · Tone failed (SIP INFO): Invalid operation [status 70013]")
        XCTAssertEqual(r.core.activeCall?.dtmfSerial, 1)
    }

    func testNonDTMFCharactersAreNotSent() async {
        let r = await connectedRig()
        r.core.sendDTMF("+")
        XCTAssertTrue(r.sip.dtmfSent.isEmpty)
        XCTAssertNil(r.core.activeCall?.dtmfStatus)
    }

    func testNoActiveCallSendsNothing() async {
        let r = makeRig(reach: [true])
        await r.core.start()
        r.core.sendDTMF("1")
        XCTAssertTrue(r.sip.dtmfSent.isEmpty)
    }

    func testCallMediaRecordedOnCallAndForDiagnostics() async {
        let r = await connectedRig()
        let info = CallMediaInfo(remoteTelephoneEventPT: 101, localTelephoneEventPT: 96, codec: "G722")
        r.core.handle(.callMedia(id: 99, info))          // other call: ignored
        XCTAssertNil(r.core.activeCall?.media)
        r.core.handle(.callMedia(id: 7, info))
        XCTAssertEqual(r.core.activeCall?.media, info)
        XCTAssertEqual(r.core.lastCallMedia,
                       "remote telephone-event: yes, payload type 101; local: yes, payload type 96; codec G722")
        r.core.handle(.callState(id: 7, .ended(code: 200, reason: "OK")))
        await r.core.waitForCallCleanup()
        XCTAssertNotNil(r.core.lastCallMedia)            // survives the call for Settings > Diagnostics
    }

    func testMediaSummaryWithoutTelephoneEvent() {
        let info = CallMediaInfo(remoteTelephoneEventPT: nil, localTelephoneEventPT: 101, codec: "PCMA")
        XCTAssertEqual(info.summary, "remote telephone-event: no; local: yes, payload type 101; codec PCMA")
    }

    func testOldStoredSettingsDecodeWithDefaultMethod() throws {
        let old = #"{"fritzHost":"192.168.178.1","sipUser":"620","tr064User":"me","countryCode":"49","areaCode":"030","keepAwakeOnPower":false,"launchAtLogin":true}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.fritzHost, "192.168.178.1")
        XCTAssertEqual(s.sipUser, "620")
        XCTAssertFalse(s.keepAwakeOnPower)
        XCTAssertTrue(s.launchAtLogin)
        XCTAssertEqual(s.dtmfMethod, .rfc2833)
    }

    func testSettingsRoundTripAndUnknownMethodFallsBack() throws {
        var s = AppSettings(); s.dtmfMethod = .both; s.sipUser = "621"
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        let odd = #"{"sipUser":"622","dtmfMethod":"smoke-signals"}"#
        let o = try JSONDecoder().decode(AppSettings.self, from: Data(odd.utf8))
        XCTAssertEqual(o.sipUser, "622")
        XCTAssertEqual(o.dtmfMethod, .rfc2833)
    }

    func testWireMethods() {
        XCTAssertEqual(DTMFMethod.both.wireMethods, [.rfc2833, .sipInfo])
        XCTAssertEqual(DTMFMethod.inband.wireMethods, [.inband])
    }
}
