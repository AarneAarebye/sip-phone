import XCTest
@testable import SIPEngine

final class UserPartTests: XCTestCase {
    func testNamedUri() { XCTAssertEqual(PJSIPEngine.userPart(of: "\"Name\" <sip:0301234@fritz.box>"), "0301234") }
    func testBareUri() { XCTAssertEqual(PJSIPEngine.userPart(of: "sip:123@host"), "123") }
    func testNoPrefix() { XCTAssertEqual(PJSIPEngine.userPart(of: "0301234"), "0301234") }
    func testParamsAndNoHost() { XCTAssertEqual(PJSIPEngine.userPart(of: "<sip:42;tag=x>"), "42") }
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
}
