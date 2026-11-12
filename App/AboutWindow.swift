// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 SIP Phone contributors

import SwiftUI
import AppKit

/// Project facts shown in the About window and in Settings.
enum AppInfo {
    static let repositoryURL = URL(string: "https://github.com/AarneAarebye/sip-phone")!
    static let copyright = "Copyright © 2026 SIP Phone contributors"
    static let licenceNotice = "Licensed under the GNU General Public License v3.0 or later. "
        + "This program comes with ABSOLUTELY NO WARRANTY."

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    /// One line per component (name, licence); the full texts are in THIRD_PARTY_LICENSES.md.
    static let components: [(name: String, licence: String)] = [
        ("PJSIP 2.15", "GPL-2.0-or-later"),
        ("WireGuardKit and wireguard-go", "MIT"),
        ("Go runtime and modules (golang.org/x/crypto, net, sys)", "BSD-3-Clause"),
        ("libsrtp (bundled with PJSIP)", "BSD-3-Clause"),
        ("Speex (bundled with PJSIP)", "BSD-3-Clause"),
        ("WebRTC audio processing (bundled with PJSIP)", "BSD-3-Clause"),
        ("libresample (bundled with PJSIP)", "LGPL-2.1"),
        ("GSM 06.10 (bundled with PJSIP)", "TU Berlin notice"),
        ("iLBC (bundled with PJSIP)", "RFC 3951 code"),
        ("G.722.1 (bundled with PJSIP)", "Polycom notice"),
    ]
}

/// Licence texts bundled in SipPhone.app/Contents/Resources.
enum BundledDocument: String {
    case thirdPartyLicences = "THIRD_PARTY_LICENSES.md"
    case licence = "LICENSE"

    var title: String {
        switch self {
        case .thirdPartyLicences: "Third-Party Licences"
        case .licence: "GNU General Public License v3.0"
        }
    }

    var text: String {
        guard let url = Bundle.main.url(forResource: rawValue, withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "\(rawValue) is missing from the app bundle. It is also available at \(AppInfo.repositoryURL.absoluteString)."
        }
        return text
    }
}

/// The About and licence windows. Each window is created once and reused, so reopening works; the app shows its
/// Dock icon while one of them (or Settings) is open, see `SettingsWindowActivator`.
@MainActor enum AboutWindows {
    private static var windows: [String: NSWindow] = [:]

    static func showAbout() {
        show(id: "about", title: "About SIP Phone", resizable: false) { AboutView() }
    }

    static func show(_ document: BundledDocument) {
        show(id: document.rawValue, title: document.title, resizable: true, size: NSSize(width: 680, height: 600)) {
            DocumentTextView(text: document.text).frame(minWidth: 420, minHeight: 300)
        }
    }

    private static func show<Content: View>(id: String, title: String, resizable: Bool, size: NSSize? = nil,
                                            @ViewBuilder content: () -> Content) {
        let window: NSWindow
        if let existing = windows[id] {
            window = existing
        } else {
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size ?? NSSize(width: 400, height: 400)),
                              styleMask: resizable ? [.titled, .closable, .miniaturizable, .resizable] : [.titled, .closable],
                              backing: .buffered, defer: true)
            window.title = title
            window.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: content().background(SettingsWindowActivator()))
            if size != nil { host.sizingOptions = [] }   // resizable: keep the given size, the view fills the window
            window.contentViewController = host   // the activator may already order it front; centring follows
            if let size { window.setContentSize(size) }
            window.center()
            windows[id] = window
        }
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("SIP Phone").font(.title2.bold())
            Text(AppInfo.version).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Text(AppInfo.copyright).font(.caption)
            Text(AppInfo.licenceNotice).font(.caption).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Link("Source code on GitHub", destination: AppInfo.repositoryURL).font(.callout)
                .help(AppInfo.repositoryURL.absoluteString)
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                Text("Open source components").font(.caption.bold())
                ForEach(AppInfo.components, id: \.name) { c in
                    Text("\(c.name): \(c.licence)").font(.caption2)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button("Third-party licences…") { AboutWindows.show(.thirdPartyLicences) }
                Button("GNU GPL v3.0…") { AboutWindows.show(.licence) }
            }.padding(.top, 4)
        }
        .padding(20)
        .frame(width: 400)
    }
}

/// Read-only, selectable, scrollable plain text (the bundled licence files).
private struct DocumentTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.string = text
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
