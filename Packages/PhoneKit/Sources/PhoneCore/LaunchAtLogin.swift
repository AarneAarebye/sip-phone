// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import Foundation

/// Mirror of SMAppService.Status so the decision logic is testable without ServiceManagement.
public enum LoginItemStatus: Sendable, CaseIterable { case notRegistered, enabled, requiresApproval, notFound }
public enum LoginItemAction: Sendable, Equatable { case none, register, unregister }

public enum LaunchAtLogin {
    /// register() throws when already registered and unregister() when not registered, so only act when needed.
    public static func action(desired: Bool, status: LoginItemStatus) -> LoginItemAction {
        if desired { return status == .enabled ? .none : .register }
        return (status == .enabled || status == .requiresApproval) ? .unregister : .none
    }
    /// What the toggle should show for the real status.
    public static func isOn(_ status: LoginItemStatus) -> Bool { status == .enabled || status == .requiresApproval }
}
