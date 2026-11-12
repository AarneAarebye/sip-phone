# SIP Phone

Using the app? See [docs/SETUP.md](docs/SETUP.md). Deutsche Anleitung: [docs/SETUP.de.md](docs/SETUP.de.md).

A macOS menu bar SIP phone for a FRITZ!Box. It registers as an IP telephone on the FRITZ!Box, shows incoming calls as notifications with the name from the FRITZ!Box phone books, lets you place calls, and shows the call history. When you are away from home it can reach the FRITZ!Box through a full-tunnel WireGuard VPN.

Targets: macOS 14 or later, universal binary (arm64 and x86_64, so Apple Silicon and Intel Macs). Bundle ids: `com.aarneaarebye.sipphone` (app) and `com.aarneaarebye.sipphone.PacketTunnel` (VPN system extension). Team ID: `LKF7C4WS72`.

## Features (v1)

- SIP registration with the FRITZ!Box, outgoing and incoming calls, mute, DTMF.
- Incoming call notifications with Answer and Decline; the caller is looked up in all FRITZ!Box phone books (merged). The called number is shown when the FRITZ!Box sends it (best effort, depends on the SIP headers).
- Call history from the FRITZ!Box call list (TR-064), including missed calls and fax calls.
- Contacts cached locally; cached contacts are used when the FRITZ!Box cannot be reached.
- WireGuard VPN for use away from home. At home the app does not start it.
- Keypad tones are sent as in-band audio by default, the only method that reaches the phone on the FRITZ!Box 6591 Cable; RFC 2833 and SIP INFO can be selected in Settings > Diagnostics.
- Optional keep-awake while on AC power, and launch at login (both in Settings).

## Repository layout

- `App/`: the menu bar app (SwiftUI), `AppEnvironment.swift` wires everything together.
- `PacketTunnel/`: the WireGuard packet tunnel provider, packaged as a system extension.
- `Packages/PhoneKit/`: Swift package with the logic (`PhoneCore`, `FritzTR064`, `SIPEngine`, `PJBridge`, `VPN`, `SystemAdapters`) and the dev tools `fritzdump` and `siptool`.
- `Packages/WireGuardKit/`: vendored copy of WireGuardKit from wireguard-apple (MIT). Upstream no longer resolves with Xcode 27, so it is copied here. Its Go bridge is built with the local Go toolchain through a make target.
- `scripts/build-pjsip.sh`: builds the PJSIP xcframework. `scripts/release.sh`: signed, notarized release build.
- `docs/`: design spec and plan (`docs/superpowers/`), `docs/MANUAL_TEST.md`, and [docs/RELEASE.md](docs/RELEASE.md) (signing, notarization and distribution).

## Build

Prerequisites: Xcode (developed with Xcode 27), Homebrew.

```
brew install xcodegen go
scripts/build-pjsip.sh      # universal PJSIP xcframework, git-ignored, takes about 2 minutes
xcodegen                    # generates SipPhone.xcodeproj from project.yml
open SipPhone.xcodeproj   # build and run the SipPhone scheme
```

To build under a different team or prefix, change `DEVELOPMENT_TEAM`, `bundleIdPrefix` and the bundle ids (also the extension id in `App/AppEnvironment.swift`) in `project.yml` and the sources.

Unit tests: `cd Packages/PhoneKit && swift test`.

Debug builds use automatic development signing with Xcode-managed profiles and the plain `packet-tunnel-provider` Network Extension value (`App/SipPhone.Debug.entitlements`, `PacketTunnel/PacketTunnel.Debug.entitlements`); Release uses Developer ID signing with the `packet-tunnel-provider-systemextension` value (`*.entitlements`). To get development profiles, run `xcodebuild -scheme SipPhone -destination 'platform=macOS' -configuration Debug -allowProvisioningUpdates build` once, adding `-allowProvisioningDeviceRegistration` to register a new Mac. A Release signed build requires Developer ID provisioning profiles for both bundle ids (see docs/RELEASE.md). Without signing, `xcodebuild -scheme SipPhone -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` still compiles everything.

## App icon

The app icon lives in `App/Assets.xcassets/AppIcon.appiconset` (all macOS sizes, 16 to 1024 px) and is drawn by `scripts/make-icon.swift`: a dark rounded square with a green frame, a phone handset and a dot, in the same style as the Dossiary icon. The handset is our own vector drawing (a symmetric band swept along an arc, with rounded cups, built with CoreGraphics path operations), not an SF Symbol or other third-party artwork. Every size is rendered natively; at 32 px and below the frame stroke and the handset grip are thickened, and at 16 px the dot is left out. To regenerate after changing the script: `swift scripts/make-icon.swift App/Assets.xcassets/AppIcon.appiconset`, then rebuild. The output is deterministic, so unchanged code produces identical PNGs.

## Releasing

`scripts/release.sh` builds a universal, Developer ID signed, notarized and stapled `build/release/SipPhone.dmg`. `scripts/release.sh --unsigned` is a dry run (archive plus universal check, no signing). Notarization uses an App Store Connect API key in `~/.config/apple-api/` (`api-key.env` with `KEY_FILE`, `KEY_ID`, `ISSUER`, plus the `.p8` key file; modes 600, folder 700; override the folder with `SIPPHONE_NOTARY_DIR`; the Keychain profile `sipphone-notary` (a Keychain item, not a folder) remains a fallback). That folder lives outside the repository and must never be committed. Prerequisites (certificate, two provisioning profiles, notary credentials) and troubleshooting are in [docs/RELEASE.md](docs/RELEASE.md).

## VPN (system extension)

The VPN is a full-tunnel WireGuard connection implemented as a macOS system extension, which is what Developer ID distribution requires. On first start macOS asks you to approve the extension in System Settings > General > Login Items & Extensions > Network Extensions. The WireGuard configuration is pasted into Settings and stored in the Keychain; the app hands it to the extension when the tunnel starts, it is never stored in the VPN settings. Calls away from home need the VPN. Quitting the app stops it.

Status: the system extension activation has not yet been exercised on a real system, because that needs the provisioning profiles above.

## FRITZ!Box prerequisites

1. An IP telephone: Telephony > Telephony Devices > Set up new device > IP telephone. Its user name and password are the SIP login in Settings.
2. A FRITZ!Box user with the "Phone" and "FRITZ!Box settings" rights, used for TR-064 (phone books and call list). TR-064 must be enabled: Home Network > Network > Network Settings > Home Network Sharing, "Allow access for applications".
3. For use away from home, a WireGuard connection for the Mac: Internet > Permit Access > VPN (WireGuard). Export its `.conf` and paste it into Settings.

The FRITZ!Box typically has several phone numbers, including a fax number. Outgoing calls use the number assigned to the IP telephone in the FRITZ!Box. Fax calls are listed in History.

## Behaviour notes

- The Mac only rings while it is awake. While on AC power the app holds a no-idle-sleep assertion (can be switched off in Settings). Calls missed during sleep appear in History after wake.
- The FRITZ!Box TLS certificate is pinned on first use. The pin is also how the app recognises your own FRITZ!Box at home: another FRITZ!Box (for example on a visited network) counts as "not at home" and the VPN is started. After replacing or resetting your FRITZ!Box, click "Forget pinned certificate" in Settings; until then the app reports "The FRITZ!Box certificate changed…" or keeps starting the VPN at home. The app is sandboxed, so a plain `defaults delete com.aarneaarebye.sipphone …` does not reach its preferences; from Terminal, quit the app and run `defaults delete ~/Library/Containers/com.aarneaarebye.sipphone/Data/Library/Preferences/com.aarneaarebye.sipphone tr064CertFingerprint`.
- Microphone access is required for calls.

## Dev tools

Run from `Packages/PhoneKit`:

- `FRITZ_USER=… FRITZ_PASS=… [FRITZ_HOST=fritz.box] swift run fritzdump` prints the first contacts and calls from TR-064.
- `SIP_HOST=fritz.box SIP_USER=… SIP_PASS=… swift run siptool [number]` registers and dials the number for 20 seconds; without a number it waits 60 seconds for an incoming call. `SIP_HOST` defaults to `fritz.box`.

## Testing

See `docs/MANUAL_TEST.md` for the manual checklist.

## Out of scope in v1, ideas for later

Not in v1: phone book editing, call hold, video, multiple accounts, push wake-ups for a sleeping Mac.

Ideas: check whether CallKit is usable on macOS, an iPhone companion app, a Call Directory extension.
