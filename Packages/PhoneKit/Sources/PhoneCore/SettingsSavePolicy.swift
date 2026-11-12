// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import Foundation

public enum SettingsSavePolicy {
    /// The Settings window closes after Save only when there is nothing the user must read.
    public static func shouldCloseAfterSave(saveError: String?, loginItemMessage: String?) -> Bool {
        saveError == nil && loginItemMessage == nil
    }
}
