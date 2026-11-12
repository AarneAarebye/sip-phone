// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import Foundation
import FritzTR064

final class MemoryPin: PinStore, @unchecked Sendable {
    private var value: String?
    func load() -> String? { value }
    func save(_ fingerprint: String) { value = fingerprint; print("pinned certificate \(fingerprint.prefix(16))…") }
}

let env = ProcessInfo.processInfo.environment
guard let user = env["FRITZ_USER"], let pass = env["FRITZ_PASS"] else {
    print("usage: FRITZ_USER=… FRITZ_PASS=… [FRITZ_HOST=fritz.box] fritzdump"); exit(2)
}
let transport = URLSessionTransport(username: user, password: pass, pins: MemoryPin())
let client = FritzTR064Client(host: env["FRITZ_HOST"] ?? "fritz.box", transport: transport)
do {
    let contacts = try await client.loadContacts()
    print("\(contacts.count) contacts"); contacts.prefix(5).forEach { print(" -", $0.name, $0.numbers.map(\.number)) }
    let calls = try await client.loadCallList()
    print("\(calls.count) calls"); calls.prefix(5).forEach { print(" -", $0.type, $0.remoteNumber, $0.date) }
} catch { print("error:", error); exit(1) }
