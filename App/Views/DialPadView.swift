import SwiftUI
import AVFoundation
import AppKit
import PhoneCore

enum Microphone {
    static func ensureAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            return false
        }
    }

    /// Dials after making sure the microphone may be used; otherwise reports the error to the UI.
    @MainActor static func dial(_ number: String, core: AppCore) {
        Task {
            if await ensureAccess() { core.dial(number) }
            else { core.reportError("Microphone access denied – allow it in System Settings") }
        }
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
