# Follow-ups after the first implementation

Findings that were reviewed, judged not to block the first merge, and deferred. Grouped by area; nothing here is known to lose data or leak secrets.

## Should be done soon
- **Pin mismatch message.** If the FRITZ!Box certificate changes, the reachability probe reports "unreachable", the VPN starts at home, and the message hides the cause. Report a pin mismatch separately and show an offline message that names Settings > "Forget pinned certificate".
- **Activate the VPN system extension earlier.** Activation is first requested only when the box is unreachable, so the approval prompt appears away from home. Request it right after the WireGuard config is saved.
- **Calls and IP changes.** No `handleIpChange`/re-INVITE after a local IP change, so audio may stay dead although signalling survives. In-call deferral does not cover the reconnect loop; the `setRegistration(true)` throw fallback recreates the account and ends the call.
- **Number forms.** `0049 (0)30…` and `+49-(0)30…` are not normalised.

## Robustness and polish
- **TR-064:** parser errors surface as NSError instead of `FritzError.malformedXML`; unparseable or unknown call types are dropped silently; fallback ids can collide; SOAP faults without `errorCode` are not recognised; sticky `pinRejected` can mislabel later cancelled requests; URLSession is never invalidated on exit.
- **AppCore:** `bookTask` is not cleared at shutdown and not re-run after a Settings Save; a non-auth registration failure while "not configured" starts a polling loop.
- **Keychain/settings:** delete-then-add instead of `SecItemUpdate`; adding a settings key resets all settings (custom `init(from:)`); contacts cache is plain JSON in the sandbox container.
- **UI:** panel `collectionBehavior` for Spaces/full-screen; no ringtone loop; errors visible only while the popover is open; `AnyView` in the main view; duplicate-number ids in the contact list; search does not normalise numbers; the WireGuard editor shows the key in clear text.
- **VPN:** the config check in the app and the extension parser disagree on unknown keys; `.requestCanceled` is reported as "not approved"; the first of several managers is used; no tunnel stop when back home; connect-during-disconnect race at quit.
- **System:** path signature is order-sensitive; UPS counts as not-AC; assertion creation failure is silent.
- **Release:** `--help` range, SIGPIPE-safe identity resolution, expiry check fails open, sign by hash, certificate name printed in logs; pin the Go toolchain; `.gitignore` entries for `.swiftpm/` and `xcuserdata/`.
- **PJSIP:** restrict unused codecs at build time; `CXXFLAGS`/`-O2` check; consider the latest 2.x release.

## Tests worth adding
Gated non-cancellable backend for the VPN cancellation checks; wake during reconnect; shutdown then start; Keychain, settings and cache stores; `tel:` called-number parsing.

## Not yet verified on real systems
See `docs/MANUAL_TEST.md`: SIP registration and calls against the FRITZ!Box, mute direction, called-number headers, VPN system-extension activation and tunnel, signed/notarized release, Intel iMac (macOS Tahoe 26).
