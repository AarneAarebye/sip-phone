# Manual test checklist

Record pass or fail for each line. Needs a FRITZ!Box with an IP telephone and TR-064 user, a mobile phone, and for the away-from-home items a second network (for example a phone hotspot).

## Core checklist

1. At home: the app starts "Connected" without starting the VPN; phone book and history load.
2. Outgoing call to a mobile: it rings, audio works both ways, mute silences the mic, DTMF tones are heard by an IVR, hang-up works.
3. Incoming call: the notification shows the phone book name, Answer connects, Decline rejects; an unknown number shows the number.
4. Away from home (hotspot): the app starts the VPN itself and everything above still works; quitting stops the VPN.
5. Wrong SIP password: "Login rejected" with no retry storm. Wrong TR-064 password: cached contacts with a notice.
6. Sleep/wake and Wi-Fi switch recover automatically; the keep-awake assertion follows AC/battery.
7. The launch at login toggle works after a re-login.

## Additional live checks

8. Settings window: open, close and reopen it from the menu; it comes to the front each time, the Dock icon appears while it is open and disappears when it is closed.
9. Phone book and call list load, both with `fritzdump` and in the app.
10. SIP registration works, both with `siptool` and in the app.
11. Outgoing and incoming call audio works in both directions.
12. Mute really silences the microphone: listen on the remote side.
13. Keypad tones use in-band audio by default (Settings > Diagnostics > Keypad tone method): during a call to a mobile, the person on the remote side hears the beeps for each key pressed and the in-call keypad shows "sent via In-band audio tones (recommended)".

    **Keypad tones (DTMF):** during a connected call, open the in-call keypad and press a digit. The caption under the keypad says whether the tone was sent and with which method ("Tone sent via RFC 2833", or "Tone failed (RFC 2833): <PJSIP error>"); the line below it (and Settings > Diagnostics "Last call") shows whether the remote side offered telephone-event and its payload type. Then try each "Keypad tone method" in Settings > Diagnostics (RFC 2833, SIP INFO, RFC 2833 + SIP INFO, In-band audio; click Save, which also works during a call) and report which one the remote side actually hears, together with the caption text and the "Last call" line. The digits are never shown or logged; `log stream --level info --predicate 'subsystem == "com.aarneaarebye.sipphone" AND category == "dtmf"'` shows only counts, method and PJSIP status.

14. Incoming call shows the called number correctly for each of your phone numbers (including the fax number if applicable).
15. Microphone permission denied: the app shows the expected message and recovers after permission is granted.
16. Notification actions: Answer and Decline work from the notification, also when the app is in the background.
17. VPN: the system extension approval prompt appears on first use and, once approved (System Settings > General > Login Items & Extensions > Network Extensions), the tunnel starts away from home and stops on quit.
18. Sleep/wake: after wake the registration is restored and missed calls appear in History.
19. Wi-Fi switch: after changing networks the registration recovers.
20. Keep-awake: `pmset -g assertions` shows the app's assertion on AC power, and not on battery or when the setting is off.
21. Intel iMac (macOS Tahoe 26): the app launches and items 1 to 3 pass.

## Final review scenarios

22. Network change during a call: during a connected call, switch Wi-Fi (or plug in Ethernet). The call continues (audio may pause briefly); after hang-up the registration is refreshed and the status returns to "Connected".
23. Settings Save during a call: during a connected call, open Settings and click Save (with and without changes). The call continues; the re-registration happens after hang-up.
24. Incoming call after a long idle period: leave the Mac idle (display off, app in the background) for an hour or more on AC power, then call it. It rings promptly (no App Nap delay); `pmset -g assertions` lists the app's user-initiated activity.
25. Visiting another FRITZ!Box network: on a network whose router is a different FRITZ!Box (reachable at the same address), the app does not treat it as home: it starts the VPN and registers through the tunnel.
26. WAN IP change while on VPN: away from home with the tunnel up, make the home FRITZ!Box get a new public IP (reconnect the internet connection in the FRITZ!Box). The app notices the FRITZ!Box is unreachable, restarts the tunnel and registers again; a VPN error, if any, is shown in the window.
27. Typing in another app while a call rings: keep typing (including Return) in another app when an incoming call arrives. The call panel appears but does not take keyboard focus and the call is not answered; clicking Answer (or clicking the panel and pressing Return) answers.
28. The app must be in /Applications for the system extension to activate: run it from elsewhere (for example the DMG or Downloads) and confirm the VPN activation fails with a clear message; after moving it to /Applications, activation works.
29. Forget pinned certificate: in Settings, "Forget pinned certificate" clears the pin; the next connection pins the current certificate again and the phone book loads.
30. Keypad: long-press 0 and the + button type a leading +; both are unavailable once the field has text; the in-call keypad has neither.
31. Settings Save: a successful Save closes the Settings window (Dock icon disappears); on a save error or a login-item hint the window stays open and shows the message.
32. Call end messages: hanging up an answered call (as caller or callee) shows "Call ended"; the other side hanging up shows "Call ended by the other party"; declining an incoming call shows "Call declined"; the caller giving up before you answer shows "Missed call"; cancelling your own ringing call shows "Call cancelled"; calling a busy number shows "Busy". None of these appear as a red error, and none says "Decline".
33. Hidden previews: with System Settings > Notifications > SIP Phone > Show Previews set to Never, the incoming-call banner still shows the caller and "Incoming call" (not "Notification").
34. Phone book selection: with two or more FRITZ!Box phone books, the Contacts tab shows a menu next to the search box ("All phone books" plus each book) that filters together with the search. In Settings > Phone books switch one book off and Save: its contacts vanish from Contacts (and the menu), and an incoming call from one of its numbers shows only the number (names in History come from the FRITZ!Box call list and do not change). Switch it on again and Save: contacts and names return. Switching all books off shows "All phone books are switched off".
35. About window: "About SIP Phone…" in the popover (and in Settings > About & licences) opens the About window in front, with the Dock icon shown; it shows the app icon, the version from the bundle, "Copyright © 2026 SIP Phone contributors" and the GPL notice. Close it (Dock icon disappears) and open it again: it comes to the front again. "Source code on GitHub" opens https://github.com/AarneAarebye/sip-phone in the browser. "Third-party licences…" opens a scrollable, read-only window whose text can be selected and copied; scrolling shows the PJSIP (GPL-2.0) and WireGuard (MIT) licence texts. "GNU GPL v3.0…" shows the full GPL text. With Settings and the About window both open, closing one keeps the Dock icon until the other closes.
