// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let env = AppEnvironment()
    private lazy var callWindow = CallWindowController(core: env.core)
    private lazy var notifications = NotificationService(core: env.core)
    /// Held for the app lifetime: App Nap would otherwise throttle the SIP event timer and delay incoming calls.
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "SIP registration and incoming calls")
        notifications.setUp()
        SipPhone.observe { [self] in   // module-qualified: NSObject.observe(_:) would shadow the global
            _ = env.core.activeCall          // establishes the observation (any change of the call re-runs this)
            callWindow.update(); notifications.update()
        }
        env.monitors.start()
        Task { await env.core.start() }
    }
    /// Lets shutdown (unregister, VPN stop) finish, but never blocks quitting for more than a few seconds.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        var replied = false
        env.monitors.stop()
        func reply() {
            guard !replied else { return }; replied = true
            if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in await env.core.shutdown(); reply() }
        Task { @MainActor in try? await Task.sleep(for: .seconds(4)); reply() }
        return .terminateLater
    }
}
