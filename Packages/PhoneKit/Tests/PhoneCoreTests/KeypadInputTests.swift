// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import XCTest
@testable import PhoneCore

final class KeypadInputTests: XCTestCase {
    func testPlusAllowed() {
        XCTAssertTrue(KeypadInput.plusAllowed(currentText: ""))
        XCTAssertTrue(KeypadInput.plusAllowed(currentText: "  \n"))
        XCTAssertFalse(KeypadInput.plusAllowed(currentText: "030"))
        XCTAssertFalse(KeypadInput.plusAllowed(currentText: "+49"))
        XCTAssertFalse(KeypadInput.plusAllowed(currentText: "*31#"))
    }
    func testApplyPlus() {
        XCTAssertEqual(KeypadInput.applyPlus(to: ""), "+")
        XCTAssertEqual(KeypadInput.applyPlus(to: " "), "+")
        XCTAssertEqual(KeypadInput.applyPlus(to: "+49"), "+49")
    }
    func testZeroLongPress() {
        XCTAssertEqual(KeypadInput.applyZeroLongPress(to: ""), "+")
        XCTAssertEqual(KeypadInput.applyZeroLongPress(to: "03"), "030")
        XCTAssertEqual(KeypadInput.applyZeroLongPress(to: "+"), "+0")
    }
}
