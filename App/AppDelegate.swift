import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let env = AppEnvironment()
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await env.core.start() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        // Best effort: real shutdown (unregister/VPN stop) is awaited in Task 10.
    }
}
