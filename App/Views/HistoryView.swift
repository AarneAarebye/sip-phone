// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 SIP Phone contributors

import SwiftUI
import PhoneCore

struct HistoryView: View {
    let core: AppCore
    var body: some View {
        List(core.history) { r in
            HStack {
                Image(systemName: icon(r.type)).foregroundStyle(r.type == .missed ? .red : .secondary)
                VStack(alignment: .leading) {
                    Text(r.name ?? r.remoteNumber).font(.headline)
                    Text(r.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Microphone.dial(r.remoteNumber, core: core) } label: { Image(systemName: "phone") }.buttonStyle(.borderless)
            }
        }
        .task { await core.refreshHistory() }
    }
    private func icon(_ t: CallRecordType) -> String {
        switch t {
        case .incoming: "phone.arrow.down.left"; case .missed: "phone.down"
        case .outgoing: "phone.arrow.up.right"; case .rejected: "phone.down.circle"
        }
    }
}
