import XCTest
@testable import SIPEngine

final class UserPartTests: XCTestCase {
    func testNamedUri() { XCTAssertEqual(PJSIPEngine.userPart(of: "\"Name\" <sip:0301234@fritz.box>"), "0301234") }
    func testBareUri() { XCTAssertEqual(PJSIPEngine.userPart(of: "sip:123@host"), "123") }
    func testNoPrefix() { XCTAssertEqual(PJSIPEngine.userPart(of: "0301234"), "0301234") }
    func testParamsAndNoHost() { XCTAssertEqual(PJSIPEngine.userPart(of: "<sip:42;tag=x>"), "42") }
}
