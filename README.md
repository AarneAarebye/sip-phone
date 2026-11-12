# FritzPhone

A macOS menu bar SIP phone for a FRITZ!Box. It registers as an IP telephone on the FRITZ!Box, shows incoming calls as notifications with the name from the FRITZ!Box phone books, lets you place calls, and shows the call history. When you are away from home it can reach the FRITZ!Box through a full-tunnel WireGuard VPN.

Targets: macOS 14 or later, universal binary (arm64 and x86_64, so Apple Silicon and Intel Macs). Bundle ids: `com.aarneaarebye.fritzphone` (app) and `com.aarneaarebye.fritzphone.PacketTunnel` (VPN system extension). Team ID: `LKF7C4WS72`.

## Features (v1)

- SIP registration with the FRITZ!Box, outgoing and incoming calls, mute, DTMF.
- Incoming call notifications with Answer and Decline; the caller is looked up in all FRITZ!Box phone books (merged). The called number is shown when the FRITZ!Box sends it (best effort, depends on the SIP headers).
- Call history from the FRITZ!Box call list (TR-064), including missed calls and fax calls.
- Contacts cached locally; cached contacts are used when the FRITZ!Box cannot be reached.
- WireGuard VPN for use away from home. At home the app does not start it.
- Optional keep-awake while on AC power, and launch at login (both in Settings).

## Repository layout

- `App/`: the menu bar app (SwiftUI), `AppEnvironment.swift` wires everything together.
- `PacketTunnel/`: the WireGuard packet tunnel provider, packaged as a system extension.
- `Packages/PhoneKit/`: Swift package with the logic (`PhoneCore`, `FritzTR064`, `SIPEngine`, `PJBridge`, `VPN`, `SystemAdapters`) and the dev tools `fritzdump` and `siptool`.
- `Packages/WireGuardKit/`: vendored copy of WireGuardKit from wireguard-apple (MIT). Upstream no longer resolves with Xcode 27, so it is copied here. Its Go bridge is built with the local Go toolchain through a make target.
- `scripts/build-pjsip.sh`: builds the PJSIP xcframework.
- `docs/`: design spec and plan (`docs/superpowers/`), `docs/MANUAL_TEST.md`, and `docs/RELEASE.md` (planned, not written yet: signing, notarization and distribution).

## Build

Prerequisites: Xcode (developed with Xcode 27), Homebrew.

```
brew install xcodegen go
scripts/build-pjsip.sh      # universal PJSIP xcframework, git-ignored, takes about 2 minutes
xcodegen                    # generates FritzPhone.xcodeproj from project.yml
open FritzPhone.xcodeproj   # build and run the FritzPhone scheme
```

To build under a different team or prefix, change `DEVELOPMENT_TEAM`, `bundleIdPrefix` and the bundle ids (also the extension id in `App/AppEnvironment.swift`) in `project.yml` and the sources.

Unit tests: `cd Packages/PhoneKit && swift test`.

A signed build requires Apple provisioning profiles with the Network Extension and System Extension capabilities for both bundle ids. Without them the signed build fails; `xcodebuild -scheme FritzPhone -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` still compiles everything.

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
- The FRITZ!Box TLS certificate is pinned on first use. After replacing the FRITZ!Box, reset the pin: `defaults delete com.aarneaarebye.fritzphone tr064CertFingerprint`.
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
