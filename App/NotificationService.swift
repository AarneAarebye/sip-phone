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
        center.setNotificationCategories([UNNotificationCategory(identifier: "INCOMING", actions: [
            UNNotificationAction(identifier: "ANSWER", title: "Answer", options: [.foreground]),
            UNNotificationAction(identifier: "DECLINE", title: "Decline", options: [.destructive]),
        ], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
        c.categoryIdentifier = "INCOMING"; c.sound = .defaultCritical
        center.add(UNNotificationRequest(identifier: ident, content: c, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let action = response.actionIdentifier
        Task { @MainActor in
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
