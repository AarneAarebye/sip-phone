// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import XCTest
@testable import PhoneCore

final class SettingsSavePolicyTests: XCTestCase {
    func testClosesWhenNothingToRead() {
        XCTAssertTrue(SettingsSavePolicy.shouldCloseAfterSave(saveError: nil, loginItemMessage: nil))
    }
    func testStaysOnSaveError() {
        XCTAssertFalse(SettingsSavePolicy.shouldCloseAfterSave(saveError: "x", loginItemMessage: nil))
    }
    func testStaysOnLoginItemMessage() {
        XCTAssertFalse(SettingsSavePolicy.shouldCloseAfterSave(saveError: nil, loginItemMessage: "y"))
    }
    func testStaysWhenBothSet() {
        XCTAssertFalse(SettingsSavePolicy.shouldCloseAfterSave(saveError: "x", loginItemMessage: "y"))
    }
}
