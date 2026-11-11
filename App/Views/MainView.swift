import SwiftUI
import PhoneCore

struct MainView: View {
    let core: AppCore
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Picker("", selection: $tab) {
                Text("Contacts").tag(0); Text("History").tag(1)
            }.pickerStyle(.segmented).padding(8)
            Group { tab == 0 ? AnyView(ContactsView(core: core)) : AnyView(HistoryView(core: core)) }
            Divider()
            HStack {
                SettingsLink { Text("Settings…") }
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
    }
}
