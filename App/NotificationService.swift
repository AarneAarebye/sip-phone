// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import UserNotifications
import PhoneCore

@MainActor final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let core: AppCore
    private var notifiedSerial: Int?
    private var notifiedId: String?
    init(core: AppCore) { self.core = core; super.init() }

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([Self.incomingCategory()])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static let incomingPlaceholder = "Incoming call"
    static let incomingCategoryOptions: UNNotificationCategoryOptions = [.hiddenPreviewsShowTitle]

    /// With hidden previews the banner still shows the caller (title) and "Incoming call" instead of the generic "Notification".
    nonisolated static func incomingCategory() -> UNNotificationCategory {
        UNNotificationCategory(identifier: "INCOMING", actions: [
            UNNotificationAction(identifier: "ANSWER", title: "Answer", options: [.foreground]),
            UNNotificationAction(identifier: "DECLINE", title: "Decline", options: [.destructive]),
        ], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: incomingPlaceholder, options: incomingCategoryOptions)
    }

    /// Call from the observation loop whenever `core.activeCall` changes.
    func update() {
        let center = UNUserNotificationCenter.current()
        guard let call = core.activeCall, call.isIncoming, call.state == .ringing else {
            if let id = notifiedId { center.removeDeliveredNotifications(withIdentifiers: [id]); notifiedId = nil; notifiedSerial = nil }
            return
        }
        guard notifiedSerial != call.serial else { return }   // serial, not id: call ids can be reused
        notifiedSerial = call.serial
        let ident = "call-\(call.serial)"
        notifiedId = ident
        let c = UNMutableNotificationContent()
        c.title = call.displayName ?? call.remote
        c.body = call.calledNumber.map { "Incoming call on \($0)" } ?? "Incoming call"
        c.categoryIdentifier = "INCOMING"; c.sound = .default
        center.add(UNNotificationRequest(identifier: ident, content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let action = response.actionIdentifier
        let ident = response.notification.request.identifier
        Task { @MainActor in
            // Act only on the notification of the current call: a stale banner must not answer or decline a newer one.
            guard let call = core.activeCall, ident == "call-\(call.serial)" else { done(); return }
            if action == "ANSWER" {
                await Microphone.answer(core: core)   // on denial the call panel shows the explanation
            } else if action == "DECLINE" { core.hangup() }
            done()
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}
