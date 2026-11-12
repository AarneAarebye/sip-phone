// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 SIP Phone contributors

import XCTest
@testable import PhoneCore

@MainActor final class DTMFTests: XCTestCase {
    private func connectedRig(method: DTMFMethod = .inband) async -> Rig {
        let r = makeRig(reach: [true])
        await r.core.start()
        if method != AppSettings().dtmfMethod { var s = AppSettings(); s.dtmfMethod = method; r.core.updateSettings(s) }
        r.core.dial("0301234")
        r.core.handle(.callState(id: 7, .connected))
        return r
    }

    func testDefaultSendsInbandToActiveCallAndReportsSuccess() async {
        let r = await connectedRig()
        r.core.sendDTMF("5")
        XCTAssertEqual(r.sip.dtmfSent.count, 1)
        XCTAssertEqual(r.sip.dtmfSent.first?.digits, "5")
        XCTAssertEqual(r.sip.dtmfSent.first?.callId, 7)
        XCTAssertEqual(r.sip.dtmfSent.first?.method, .inband)
        XCTAssertEqual(r.core.activeCall?.dtmfStatus, "Tone sent via In-band audio tones (recommended)")
        XCTAssertEqual(r.core.activeCall?.dtmfSerial, 1)
    }

    func testFailureIsSurfacedWithoutDigits() async {
        let r = await connectedRig(method: .rfc2833)
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
        XCTAssertEqual(s.dtmfMethod, .inband)
    }

    func testSettingsRoundTripAndFallbacks() throws {
        XCTAssertEqual(AppSettings().dtmfMethod, .inband)
        for m in DTMFMethod.allCases {
            let json = #"{"sipUser":"622","dtmfMethod":"\#(m.rawValue)"}"#
            XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)).dtmfMethod, m)
        }
        var s = AppSettings(); s.dtmfMethod = .sipInfo; s.sipUser = "621"
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        for bad in ["both", "smoke-signals"] {
            let o = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"sipUser":"622","areaCode":"030","dtmfMethod":"\#(bad)"}"#.utf8))
            XCTAssertEqual(o.sipUser, "622")
            XCTAssertEqual(o.areaCode, "030")
            XCTAssertEqual(o.dtmfMethod, .inband)
        }
    }
}
