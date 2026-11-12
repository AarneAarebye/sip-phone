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
13. DTMF digits are received by the remote side.
14. Incoming call shows the called number correctly for each of your phone numbers (including the fax number if applicable).
15. Microphone permission denied: the app shows the expected message and recovers after permission is granted.
16. Notification actions: Answer and Decline work from the notification, also when the app is in the background.
17. VPN: the system extension approval prompt appears on first use and, once approved (System Settings > General > Login Items & Extensions > Network Extensions), the tunnel starts away from home and stops on quit.
18. Sleep/wake: after wake the registration is restored and missed calls appear in History.
19. Wi-Fi switch: after changing networks the registration recovers.
20. Keep-awake: `pmset -g assertions` shows the app's assertion on AC power, and not on battery or when the setting is off.
21. Intel iMac (macOS Tahoe 26): the app launches and items 1 to 3 pass.
