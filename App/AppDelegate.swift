import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let env = AppEnvironment()
    private lazy var callWindow = CallWindowController(core: env.core)
    private lazy var notifications = NotificationService(core: env.core)

    func applicationDidFinishLaunching(_ notification: Notification) {
        notifications.setUp()
        FritzPhone.observe { [self] in   // module-qualified: NSObject.observe(_:) would shadow the global
            _ = env.core.activeCall          // establishes the observation (any change of the call re-runs this)
            callWindow.update(); notifications.update()
        }
        Task { await env.core.start() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        // Best effort: real shutdown (unregister/VPN stop) is awaited in Task 10.
    }
}
