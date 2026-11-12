import XCTest
@testable import SIPEngine
import PJBridge
import PhoneCore

final class UserPartTests: XCTestCase {
    func testNamedUri() { XCTAssertEqual(PJSIPEngine.userPart(of: "\"Name\" <sip:0301234@fritz.box>"), "0301234") }
    func testBareUri() { XCTAssertEqual(PJSIPEngine.userPart(of: "sip:123@host"), "123") }
    func testNoPrefix() { XCTAssertEqual(PJSIPEngine.userPart(of: "0301234"), "0301234") }
    func testParamsAndNoHost() { XCTAssertEqual(PJSIPEngine.userPart(of: "<sip:42;tag=x>"), "42") }
}

final class CalledNumberTests: XCTestCase {
    func testHeaderValue() { XCTAssertEqual(PJSIPEngine.calledNumber(from: "<sip:0301234@fritz.box>;foo=1"), "0301234") }
    func testEmpty() { XCTAssertNil(PJSIPEngine.calledNumber(from: "  ")) }
}

final class RegistrationMappingTests: XCTestCase {
    func testPendingOutcomes() {
        XCTAssertEqual(PJSIPEngine.pendingOutcome(statusCode: 200, reason: "OK"), .success)
        XCTAssertEqual(PJSIPEngine.pendingOutcome(statusCode: 401, reason: "x"), .failure(.authFailed))
        XCTAssertEqual(PJSIPEngine.pendingOutcome(statusCode: 403, reason: "x"), .failure(.authFailed))
        XCTAssertEqual(PJSIPEngine.pendingOutcome(statusCode: 503, reason: "Busy"), .failure(.failed("503 Busy")))
        XCTAssertNil(PJSIPEngine.pendingOutcome(statusCode: 100, reason: ""))
    }
    func testLaterEventsKeepCodeSoAppCoreCanMapAuth() {
        XCTAssertEqual(PJSIPEngine.registrationEvent(statusCode: 200, reason: "OK"), .registration(.registered))
        XCTAssertEqual(PJSIPEngine.registrationEvent(statusCode: 401, reason: "Unauthorized"),
                       .registration(.failed(code: 401, reason: "Unauthorized")))
        XCTAssertNil(PJSIPEngine.registrationEvent(statusCode: 100, reason: ""))
    }

    func testMediaInfoMapsNegativePayloadTypeToNil() {
        let i = PJSIPEngine.mediaInfo(remotePT: -1, localPT: 101, codec: "G722")
        XCTAssertNil(i.remoteTelephoneEventPT)
        XCTAssertEqual(i.localTelephoneEventPT, 101)
        XCTAssertEqual(PJSIPEngine.mediaInfo(remotePT: 0, localPT: -1, codec: "").remoteTelephoneEventPT, 0)
    }
    func testBridgeMethodMapping() {
        XCTAssertEqual(PJSIPEngine.bridgeMethod(.rfc2833), .RFC2833)
        XCTAssertEqual(PJSIPEngine.bridgeMethod(.sipInfo), .sipInfo)
        XCTAssertEqual(PJSIPEngine.bridgeMethod(.inband), .inband)
    }
}
