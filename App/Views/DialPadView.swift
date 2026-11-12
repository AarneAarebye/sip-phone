import SwiftUI
import AVFoundation
import AppKit
import PhoneCore

enum MicAccess { case authorized, denied, restricted }

/// UI-layer state: why a call action was blocked by the microphone permission.
@MainActor @Observable final class MicNotice {
    static let shared = MicNotice()
    /// Answering an incoming call is blocked (shown in the call panel).
    var incoming: MicAccess?
    /// Starting an outgoing call is blocked (shown in the popover).
    var outgoing: MicAccess?

    static func message(for a: MicAccess) -> String {
        a == .restricted ? "Microphone access is restricted on this Mac (e.g. by a profile), so calls cannot be made."
                         : "Microphone access needed to make or answer calls."
    }
}

@MainActor enum Microphone {
    /// Never opens System Settings itself; callers show a message and a button.
    static func ensureAccess() async -> MicAccess {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio) ? .authorized : .denied
        case .restricted: return .restricted
        default: return .denied
        }
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    /// Dials after making sure the microphone may be used; otherwise records the reason for the popover.
    static func dial(_ number: String, core: AppCore) {
        Task {
            let a = await ensureAccess()
            if a == .authorized { MicNotice.shared.outgoing = nil; core.dial(number) }
            else { MicNotice.shared.outgoing = a }
        }
    }

    /// Answers if allowed; otherwise leaves the call ringing and flags the call panel.
    static func answer(core: AppCore) async {
        let a = await ensureAccess()
        if a == .authorized { MicNotice.shared.incoming = nil; core.answer() }
        else { MicNotice.shared.incoming = a }
    }
}

struct DialPadView: View {
    let onKey: (String) -> Void
    private let keys = [["1","2","3"],["4","5","6"],["7","8","9"],["*","0","#"]]
    var body: some View {
        VStack(spacing: 6) {
            ForEach(keys, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { k in
                        Button(k) { onKey(k) }.frame(width: 56, height: 36).font(.title3)
                    }
                }
            }
        }
    }
}

/// Dial-tab content: number display plus keypad plus call button.
struct DialTab: View {
    let core: AppCore
    @State private var number = ""
    var body: some View {
        VStack(spacing: 10) {
            TextField("Number", text: $number).textFieldStyle(.roundedBorder).multilineTextAlignment(.center).font(.title3)
            DialPadView { number += $0 }
            HStack {
                Button { if !number.isEmpty { number.removeLast() } } label: { Image(systemName: "delete.left") }
                Button("Call") { Microphone.dial(number, core: core) }
                    .buttonStyle(.borderedProminent).tint(.green).disabled(number.isEmpty || core.connection != .ready)
            }
        }.padding()
    }
}
