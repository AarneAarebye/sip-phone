// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import Foundation

/// Decision logic for the dial keypad's "+" input (long-press 0 and the + button).
public enum KeypadInput {
    /// A leading "+" is only valid when nothing but whitespace has been entered yet.
    public static func plusAllowed(currentText: String) -> Bool {
        currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The text after a "+" request: "+" when allowed, otherwise unchanged.
    public static func applyPlus(to currentText: String) -> String {
        plusAllowed(currentText: currentText) ? "+" : currentText
    }

    /// The text after a long press on "0": "+" when allowed, otherwise a normal "0".
    public static func applyZeroLongPress(to currentText: String) -> String {
        plusAllowed(currentText: currentText) ? "+" : currentText + "0"
    }
}
