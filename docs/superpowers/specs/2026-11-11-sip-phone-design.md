# SIP Phone for Fritz!Box — Design

Date: 2026-11-11

## Goal

A native macOS SwiftUI app that acts as a SIP extension on a Fritz!Box. It places and receives calls and shows the Fritz!Box phone book and call list. It works at home and away from home: away from home it brings up a WireGuard VPN to the Fritz!Box automatically.

## Decisions

- Platform: native macOS app, SwiftUI, menu bar app.
- SIP/audio engine: PJSIP (pjsua2), built as an xcframework, wrapped by a thin Objective-C++ bridge.
- Phone book and call list: Fritz!Box TR-064 over HTTPS, plain Swift, no library.
- VPN: WireGuard via a NetworkExtension packet-tunnel provider (WireGuardKit). The user has a paid Apple Developer account for the entitlement.
- Sleep: keep the Mac awake while on AC power; missed calls during sleep appear in the call history.

## v1 scope

In: place calls (dial pad, call from phone book), receive calls (notification with caller name, Answer/Decline), phone book (read-only, searchable), call history, menu bar mode, mute and DTMF, automatic VPN, launch at login.

Out: phone book editing, hold, video, multiple accounts, push wake-ups.

## Architecture

| Module | Purpose | Depends on |
|---|---|---|
| `SIPEngine` | Registers with the Fritz!Box; dial, answer, end, mute, DTMF, codecs. Exposes an `async`/`AsyncStream` API (call state, incoming-call events). | PJSIP xcframework |
| `FritzTR064` | TR-064 client (SOAP + digest auth). Phone book (`X_AVM-DE_OnTel`), call list, number-to-name lookup. | URLSession |
| `VPNManager` | Starts/stops the WireGuard tunnel (`NETunnelProviderManager`), reports state. A `PacketTunnel` extension target runs WireGuardKit. | WireGuardKit |
| `AppCore` | Coordinates the modules: startup flow, reachability, VPN, SIP registration, settings, Keychain, power assertion. | the three above |
| `UI` | Menu bar item and popover, dial pad, contact list, call history, in-call view, settings. Incoming calls via `UserNotifications` with Answer/Decline actions. | AppCore |

Rules:
- `SIPEngine`, `FritzTR064` and `VPNManager` each sit behind a protocol so `AppCore` and the UI can be tested with fakes.
- The UI never talks to PJSIP or the network directly.
- Secrets (SIP password, TR-064 login, WireGuard private key) live only in the Keychain.

Fritz!Box prerequisites (documented for the user): an "IP telephone" extension (SIP login), and a Fritz!Box user with the "Phone" and "FRITZ!Box settings" rights for TR-064.

## Data flow

**Startup**
1. Load settings and Keychain credentials; if none, show the setup screen.
2. Probe the Fritz!Box (`fritz.box` or the configured address) with a short timeout.
   - Reachable: continue to step 4.
   - Not reachable: `VPNManager` starts the tunnel, waits for it to connect, then probes again.
3. If the VPN fails or the Fritz!Box stays unreachable: "Offline" state with a Retry button; nothing else runs.
4. `SIPEngine` registers as the IP-telephone extension. Registration refreshes automatically and is redone on network change (Wi-Fi switch, VPN up/down, wake from sleep).
5. `FritzTR064` loads the phone book and call list into memory, with a short on-disk cache for fast startup.

**Outgoing call:** the UI calls `SIPEngine.dial(number)`. State changes (`calling`, `ringing`, `connected`, `ended`) arrive as an `AsyncStream` and drive the in-call view. Mute and DTMF go straight to `SIPEngine`.

**Incoming call:** PJSIP reports the call; `AppCore` looks up the caller number in the cached phone book (no network call), posts a notification with Answer/Decline and shows the popover.

**Call history:** refreshed on startup, when a call ends, and when the tab is opened.

**Shutdown:** unregister SIP; stop the VPN only if the app started it.

## Sleep and power

- On AC power, while the app runs, `AppCore` holds an `IOPMAssertion` preventing idle system sleep (the display may still sleep).
- On battery, or when the user turns the setting off, the assertion is released and the Mac sleeps normally.
- On wake: re-probe the Fritz!Box, restore the VPN if needed, re-register SIP, refresh the call list. Calls missed during sleep show up in the history as missed.
- A Fritz!Box SIP extension has no push mechanism, so a sleeping Mac cannot ring.

## Error handling

| Situation | Behavior |
|---|---|
| Fritz!Box unreachable and VPN fails | "Offline" state in the menu bar with Retry and a short reason. |
| SIP registration rejected (wrong password) | Error with a link to settings; no endless retries. |
| SIP registration lost | Automatic retry with backoff and a visible "Reconnecting" state. |
| TR-064 login fails or phone book cannot load | Use the cached phone book with a notice; calling by number still works. |
| Microphone permission denied | Clear message in the call view with a button opening System Settings. |
| Call fails (busy, no answer, invalid number) | Reason shown in the call view and logged in the history. |

Security: TR-064 uses HTTPS. The Fritz!Box certificate is self-signed, so the app pins it on first use (trust on first use) and warns if it changes.

## Testing

- Unit tests for `AppCore` (startup flow, sleep/wake, error states) with fakes of the three protocols.
- `FritzTR064`: SOAP and phone book / call list XML parsing against saved sample responses; digest authentication tests.
- Number matching (e.g. `+49 30 1234` vs `030 1234`): table-driven tests.
- `SIPEngine` and `VPNManager`: manual verification against the real Fritz!Box.

## Build order

1. Project skeleton (SwiftUI menu bar app, entitlements, Keychain settings).
2. `FritzTR064`: phone book and call list in a simple list (first proof of the Fritz!Box connection).
3. `SIPEngine`: build PJSIP as an xcframework; register, dial, receive.
4. Call UI, notifications, mute, DTMF.
5. `VPNManager` and the `PacketTunnel` extension.
6. Sleep handling, error states, polish.
