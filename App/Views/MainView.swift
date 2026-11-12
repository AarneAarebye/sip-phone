// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import SwiftUI
import PhoneCore

struct MainView: View {
    let core: AppCore
    @State private var tab = 0
    private let notice = MicNotice.shared

    var body: some View {
        VStack(spacing: 0) {
            if let call = core.activeCall { InCallRow(core: core, call: call) }
            statusBar
            if let e = core.lastError {
                HStack(alignment: .top) {
                    Text(e).font(.caption).foregroundStyle(.red).lineLimit(3)
                    Spacer()
                    Button { core.clearError() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).help("Dismiss")
                }.padding(.horizontal, 8).padding(.top, 4)
            }
            if let a = notice.outgoing {
                HStack(alignment: .top) {
                    Text(MicNotice.message(for: a)).font(.caption).foregroundStyle(.red).lineLimit(3)
                    Spacer()
                    if a == .denied { Button("Open System Settings") { Microphone.openSettings() }.font(.caption) }
                    Button { notice.outgoing = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).help("Dismiss")
                }.padding(.horizontal, 8).padding(.top, 4)
            }
            Picker("", selection: $tab) {
                Text("Contacts").tag(0); Text("History").tag(1); Text("Keypad").tag(2)
            }.pickerStyle(.segmented).padding(8)
            Group {
                switch tab {
                case 0: ContactsView(core: core)
                case 1: HistoryView(core: core)
                default: DialTab(core: core)
                }
            }
            Divider()
            HStack {
                SettingsLink { Text("Settings…") }
                Button("About SIP Phone…") { AboutWindows.showAbout() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }.padding(8)
        }.frame(width: 340, height: 460)
    }

    @ViewBuilder private var statusBar: some View {
        let (text, color): (String, Color) = switch core.connection {
        case .ready: ("Connected", .green)
        case .starting, .registering, .connectingVPN, .reconnecting: ("Connecting…", .orange)
        case .authFailed: ("Login rejected – check Settings", .red)
        case .offline(let r): ("Offline: \(r)", .red)
        }
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).lineLimit(2)
            Spacer()
            if case .offline = core.connection { Button("Retry") { Task { await core.retry() } } }
        }.padding([.horizontal, .top], 8)
        if let n = core.phoneBookNotice { Text(n).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 8) }
        if let n = core.vpnNotice { Text(n).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 8) }
    }
}

/// Top row of the popover while a call exists: the call controls stay reachable even without the call panel.
private struct InCallRow: View {
    let core: AppCore
    let call: AppCore.ActiveCall

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "phone.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("In call: \(call.displayName ?? call.remote)").font(.callout).lineLimit(1)
                status.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button("Show call window") { CallWindowController.current?.showPanel() }
                .font(.caption)
            if case .ended = call.state {} else {
                Button("Hang up") { core.hangup() }.tint(.red).buttonStyle(.borderedProminent).font(.caption)
            }
        }
        .padding(8)
        .background(Color.green.opacity(0.12))
    }

    @ViewBuilder private var status: some View {
        switch call.state {
        case .calling: Text("Calling…")
        case .ringing: Text(call.isIncoming ? "Incoming call" : "Ringing…")
        case .connected:
            if let t = call.connectedAt { Text(t, style: .timer) } else { Text("Connected") }
        case .ended: Text(call.endMessage ?? "Call ended")
        }
    }
}
