// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

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
    /// Opt-in: long-pressing 0 reports "+" instead (Keypad tab only; "+" is not a DTMF digit).
    var longPressZeroTypesPlus = false
    /// Decides whether a long press on 0 may type "+"; otherwise it acts as a normal 0.
    var plusAllowed: () -> Bool = { true }
    private let keys = [["1","2","3"],["4","5","6"],["7","8","9"],["*","0","#"]]
    var body: some View {
        VStack(spacing: 6) {
            ForEach(keys, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { k in
                        if k == "0" && longPressZeroTypesPlus {
                            ZeroKey(onKey: onKey, plusAllowed: plusAllowed)
                        } else {
                            Button(k) { onKey(k) }.frame(width: 56, height: 36).font(.title3)
                        }
                    }
                }
            }
        }
    }
}

/// The 0 key: click types 0, a ~0.5 s long press types + (when allowed) and not 0.
private struct ZeroKey: View {
    let onKey: (String) -> Void
    let plusAllowed: () -> Bool
    @State private var pressing = false
    @State private var longFired = false
    var body: some View {
        Text("0").font(.title3)
            .frame(width: 56, height: 36)
            .background(RoundedRectangle(cornerRadius: 6).fill(pressing ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.15)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            .contentShape(Rectangle())
            .onTapGesture {
                if longFired { longFired = false } else { onKey("0") }
            }
            .onLongPressGesture(minimumDuration: 0.5, perform: {
                if plusAllowed() { longFired = true; onKey("+") }
            }, onPressingChanged: { p in
                pressing = p && plusAllowed()
                if p { longFired = false }
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("0")
            .accessibilityHint("Long press for plus")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onKey("0") }
    }
}

/// Dial-tab content: number display plus keypad plus call button.
struct DialTab: View {
    let core: AppCore
    @State private var number = ""
    var body: some View {
        VStack(spacing: 10) {
            TextField("Number", text: $number).textFieldStyle(.roundedBorder).multilineTextAlignment(.center).font(.title3)
            DialPadView(onKey: { number = $0 == "+" ? KeypadInput.applyPlus(to: number) : number + $0 },
                        longPressZeroTypesPlus: true,
                        plusAllowed: { KeypadInput.plusAllowed(currentText: number) })
            HStack {
                Button { if !number.isEmpty { number.removeLast() } } label: { Image(systemName: "delete.left") }
                Button { number = KeypadInput.applyPlus(to: number) } label: { Text("+").font(.title3) }
                    .disabled(!KeypadInput.plusAllowed(currentText: number)).accessibilityLabel("Plus")
                Button("Call") { Microphone.dial(number, core: core) }
                    .buttonStyle(.borderedProminent).tint(.green).disabled(number.isEmpty || core.connection != .ready)
            }
        }.padding()
    }
}
