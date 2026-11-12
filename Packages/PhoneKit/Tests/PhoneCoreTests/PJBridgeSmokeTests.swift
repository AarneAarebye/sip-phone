import XCTest
import PJBridge

final class PJBridgeSmokeTests: XCTestCase {
    func testPJSIPLinks() { XCTAssertTrue(PJBridge.version().hasPrefix("2.")) }

    /// The bridge rejects anything outside `+?[0-9*#]+` before building a SIP URI (no engine needed).
    func testBridgeRejectsUnsafeNumbers() {
        let bridge = PJBridge()
        for bad in ["x@evil.example;transport=tcp", "030 1234", "", "+", "1+2", "12;user=phone"] {
            XCTAssertThrowsError(try bridge.dial(bad), bad) {
                XCTAssertEqual(($0 as NSError).localizedDescription, "Invalid number", bad)
            }
        }
        // a valid number gets past validation and only fails because no account exists
        XCTAssertThrowsError(try bridge.dial("+49301234#")) {
            XCTAssertEqual(($0 as NSError).localizedDescription, "Not registered")
        }
    }
}
