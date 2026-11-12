import SwiftUI
import PhoneCore

struct InCallView: View {
    let core: AppCore
    @State private var showKeypad = false
    @State private var connectedAt: Date?
    private let notice = MicNotice.shared

    var body: some View {
        if let call = core.activeCall {
            VStack(spacing: 12) {
                Text(call.displayName ?? call.remote).font(.title2).lineLimit(1)
                if call.displayName != nil { Text(call.remote).font(.caption).foregroundStyle(.secondary) }
                if call.isIncoming, let called = call.calledNumber {
                    Text("Incoming call on \(called)").font(.caption).foregroundStyle(.secondary)
                }
                statusText(call)
                if call.isIncoming, call.state == .ringing, let a = notice.incoming {
                    VStack(spacing: 6) {
                        Text(a == .restricted ? MicNotice.message(for: a) : "Microphone access needed to answer")
                            .font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                        if a == .denied { Button("Open System Settings") { Microphone.openSettings() } }
                    }
                }
                if call.state == .connected {
                    HStack(spacing: 16) {
                        Button { core.toggleMute() } label: {
                            Label(call.muted ? "Unmute" : "Mute", systemImage: call.muted ? "mic.slash.fill" : "mic.fill")
                        }
                        Button { showKeypad.toggle() } label: { Label("Keypad", systemImage: "circle.grid.3x3.fill") }
                    }
                    if showKeypad { DialPadView { core.sendDTMF($0) } }
                }
                HStack(spacing: 16) {
                    if call.isIncoming && call.state == .ringing {
                        Button("Answer") { Task { await answer() } }.tint(.green).keyboardShortcut(.defaultAction)
                        Button("Decline") { core.hangup() }.tint(.red)
                    } else if case .ended = call.state {
                        EmptyView()
                    } else {
                        Button("Hang up") { core.hangup() }.tint(.red)
                    }
                }.buttonStyle(.borderedProminent)
            }
            .padding(20).frame(width: 300)
            .onChange(of: call.state) { _, s in
                if s == .connected { connectedAt = Date() }
            }
            .onChange(of: call.serial) { _, _ in connectedAt = nil; showKeypad = false; notice.incoming = nil }
        }
    }

    @ViewBuilder private func statusText(_ call: AppCore.ActiveCall) -> some View {
        switch call.state {
        case .calling: Text("Calling…")
        case .ringing: Text(call.isIncoming ? "Incoming call" : "Ringing…")
        case .connected:
            if let t = connectedAt { Text(t, style: .timer).monospacedDigit() } else { Text("Connected") }
        case .ended(let code, let reason): Text(code == 200 || code == 487 ? "Call ended" : "Call ended: \(reason)")
        }
    }

    private func answer() async { await Microphone.answer(core: core) }   // re-checks on every tap
}
