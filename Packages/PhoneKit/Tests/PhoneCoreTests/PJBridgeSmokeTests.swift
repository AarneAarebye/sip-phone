import XCTest
import PJBridge

final class PJBridgeSmokeTests: XCTestCase {
    func testPJSIPLinks() { XCTAssertTrue(PJBridge.version().hasPrefix("2.")) }
}
