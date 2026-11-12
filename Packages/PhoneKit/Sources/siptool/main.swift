// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 SIP Phone contributors

import Foundation
import PhoneCore
import SIPEngine

// usage: SIP_HOST=fritz.box SIP_USER=… SIP_PASS=… siptool [number-to-dial]
let env = ProcessInfo.processInfo.environment
guard let user = env["SIP_USER"], let pass = env["SIP_PASS"] else { print("set SIP_USER and SIP_PASS"); exit(2) }

Task { @MainActor in
    let engine = PJSIPEngine()
    Task { for await e in engine.events { print("event:", e) } }
    do {
        try await engine.register(SIPConfig(host: env["SIP_HOST"] ?? "fritz.box", user: user, password: pass))
        print("registered")
        if CommandLine.arguments.count > 1 {
            let id = try engine.dial(CommandLine.arguments[1]); print("dialing, call id", id)
            try? await Task.sleep(for: .seconds(20)); engine.hangup(id)
        } else {
            print("waiting 60 s for an incoming call…"); try? await Task.sleep(for: .seconds(60))
        }
        engine.unregister(); engine.shutdown(); exit(0)
    } catch { print("error:", error); exit(1) }
}
RunLoop.main.run()
