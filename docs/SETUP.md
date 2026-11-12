Deutsche Version: [SETUP.de.md](SETUP.de.md)

# SIP Phone: setup guide

This guide is for FRITZ!Box owners who want to use SIP Phone on a Mac. You do not need to be a developer to follow it.

## 1. What it does and what you need

SIP Phone is a small phone for your Mac that lives in the menu bar. It signs in to your FRITZ!Box as an IP telephone. You can place and answer calls, see who is calling (by name, from your FRITZ!Box phone books) and browse your call history.

You need:

- A Mac with macOS 14 or later (Apple Silicon or Intel).
- A FRITZ!Box with an IP telephone extension, on the same network as the Mac.
- Optional: a WireGuard connection on the FRITZ!Box if you want to use the phone away from home (see section 7).

## 2. Getting the app

There is no ready-to-download, notarized version yet. No release has been published so far. For now the app has to be built from source: follow the "Build" section in the [README](../README.md). If a download becomes available, it will be announced in the repository.

Once you have `SipPhone.app`:

1. Move it to the `/Applications` folder. This is required for the VPN extension to work (see section 7).
2. Open it. There is no Dock icon and no window. Look for the phone icon in the menu bar at the top right of your screen.
3. If you do not see the icon, it may be hidden. On Macs with a notch, or with a menu bar manager installed, icons can end up behind the notch or in the manager's overflow area. Hold the Command key (⌘) and drag other icons away to make room, or open your menu bar manager's overflow.

Click the icon to open the popover. It shows a status line, three tabs (Contacts, History, Keypad), and the buttons Settings… and Quit.

## 3. Prepare the FRITZ!Box

Open the FRITZ!Box web interface (usually `http://fritz.box`) and sign in. FRITZ!Box menus are usually in German, so the German names are given in parentheses. Exact menu names vary with the FRITZ!OS version; these steps were written against FRITZ!OS 8.25, and yours may look different.

### 3a. Create an IP telephone

1. Go to Telephony > Telephony Devices (Telefonie > Telefoniegeräte).
2. Click Set up new device (Neues Gerät einrichten).
3. Choose Telephone (with and without answering machine) (Telefon (mit und ohne Anrufbeantworter)), then LAN/WLAN (IP telephone) (LAN/WLAN (IP-Telefon)).
4. Pick a name for the phone, for example "Mac".
5. On the Login data tab (Anmeldedaten), note the user name the FRITZ!Box generated and set or note the password. You will enter both in the app as the "phone extension" login.
6. Choose which of your phone numbers should ring this phone, and which number it uses for outgoing calls. The outgoing number is set here, not in the app.
7. Finish the wizard and apply the changes.

### 3b. Create a FRITZ!Box user for the phone book and call list

The app reads your phone books and call list over a different login than the telephone.

1. Go to System > FRITZ!Box Users (System > FRITZ!Box-Benutzer) and add a user with a password.
2. Give the user the rights for FRITZ!Box settings (FRITZ!Box Einstellungen) and for voice messages, fax messages, FRITZ!App Fon and call list (Sprachnachrichten, Faxnachrichten, FRITZ!App Fon und Anrufliste).

These are the rights as best known. If the app later reports that the FRITZ!Box "rejected" the user name or password even though they are correct, see section 8 and try adding or removing rights.

### 3c. Allow access for applications (TR-064)

Make sure the FRITZ!Box allows access for applications. The menu path may differ: it is usually under Home Network > Network > Network Settings > Home Network Sharing (Heimnetz > Netzwerk > Netzwerkeinstellungen > Heimnetzfreigaben), with an option like "Allow access for applications" (Zugriff für Anwendungen zulassen).

## 4. First start and Settings

Click the menu bar icon, then Settings…. Fill in the fields below, then click Save.

| Settings field | What to enter |
|---|---|
| **Address** | `fritz.box`, or the IP address of your FRITZ!Box. |
| **Phone extension user (SIP)** | The user name of the IP telephone from step 3a. |
| **SIP password (leave empty to keep)** | The password of the IP telephone from step 3a. |
| **FRITZ!Box user (TR-064)** | The FRITZ!Box user from step 3b. |
| **TR-064 password (leave empty to keep)** | That user's password. |
| **Country code** | Your country code without `+` or `00`. The default is `49` (Germany). |
| **Local area code (e.g. 030)** | Your local area code, so numbers dialled without one still work. |
| **Keep Mac awake while on power** | On by default. Keeps the Mac from idle sleep on mains power so it can ring. |
| **Launch at login** | Starts the app when you sign in. macOS may ask you to approve it in System Settings > General > Login Items. |
| **Phone books** | One switch per FRITZ!Box phone book, all on by default; new books start on. A switched-off book is hidden in Contacts and not used to show caller names. Applied with Save. Names shown in History come from the FRITZ!Box's own call list, so switching a phone book off in the app does not change them. Shows "Not loaded yet" until the first successful load. |
| **VPN (WireGuard)** | Only for use away from home, see section 7. |
| **Keypad tone method** (Diagnostics) | Leave on "In-band audio tones (recommended)". |

The Diagnostics section also has:

- **Test TR-064 login**: checks the saved FRITZ!Box user and password and shows a verdict. It contains no user name or password, so it is safe to copy and share.
- **Forget pinned certificate**: see section 8. The Certificate section shows whether a certificate is pinned.

How passwords are handled:

- Passwords are stored in the macOS Keychain, never in a plain file.
- After saving, a password field shows "Stored in Keychain" with a check mark next to it.
- Leaving a password field empty keeps the stored password. Type a new one only to change it.

Save stores everything, reconnects, and closes the Settings window on success. If something goes wrong, the window stays open and shows a red message.

A healthy start looks like this: the popover shows a green dot with "Connected", and the Contacts and History tabs fill with your phone book entries and calls.

## 5. Permissions macOS will ask for

| Permission | What for | If you deny it |
|---|---|---|
| **Microphone** | Making and answering calls. Asked on the first call. | Calls do not start. The popover or the call window says "Microphone access needed" and offers Open System Settings. Allow SIP Phone under Privacy & Security > Microphone and try again. |
| **Notifications** | Banners for incoming calls, with Answer and Decline. | You will not see a banner, but the floating call window still appears. |
| **Local network** | macOS may ask this because the app talks to your FRITZ!Box (this may differ by macOS version). | Allow it in System Settings > Privacy & Security > Local Network if the FRITZ!Box cannot be reached. |

For notifications, open System Settings > Notifications > SIP Phone and set Show Previews to Always. With previews hidden, the banner still shows the caller and "Incoming call", but it is less informative.

## 6. Using it

**Dial from the Keypad tab.** Type or tap a number and click Call. For international numbers, long-press the 0 key or click the + button to enter a leading +. Both only work as the first character.

**Dial from Contacts.** The search box matches names, numbers and phone book names. Each contact shows which phone book it comes from. With two or more phone books switched on, a menu next to the search box ("All phone books" or one book) narrows the list; it combines with the search. Click a number to call it. You can also type a number into the search box and press Return if nothing matches.

**Dial from History.** Click the phone button on any entry.

**During a call** a call window shows the name and a timer. Use:

- **Mute / Unmute** to silence your microphone.
- **Keypad** to send tones, for example for menus on a hotline. A short caption confirms each press.
- **Hang up** to end the call.

**Incoming calls** show a floating window and a notification, both with Answer and Decline. If your FRITZ!Box has several numbers, the line "Incoming call on <number>" tells you which of your numbers was called. This is best effort: it depends on what the FRITZ!Box sends.

When a call ends, the call window shows one of these messages:

| Message | Meaning |
|---|---|
| Call ended | You hung up a call that was connected. |
| Call ended by the other party | The other side hung up. |
| Call declined | You declined an incoming call. |
| Missed call | The caller gave up before you answered. |
| Call cancelled | You cancelled your own call while it was ringing. |
| Declined by the other party | The person you called rejected the call. |
| Busy | The line is busy. |
| Not available | The number could not be reached. |
| No answer | Nobody picked up in time. |
| Call failed: <code> | Something else went wrong. Shown in red. Only this one is treated as an error. |

## 7. Away from home (WireGuard) — experimental

**Experimental: the VPN extension has not yet been tested on a real system.** Everything at home works without it. Treat this section as a preview.

To use the phone when you are away, the app connects to your FRITZ!Box through a WireGuard VPN.

1. In the FRITZ!Box, create a WireGuard connection for this Mac: Internet > Permit Access > VPN (WireGuard) (Internet > Freigaben > VPN (WireGuard)). The path may differ.
2. Export the connection as a `.conf` file.
3. Open the file in a text editor, copy all of it, and paste it into Settings under VPN (WireGuard). Click Save. The configuration is stored in the Keychain.
4. The app must be in `/Applications`. The first time the VPN is needed, macOS blocks the network extension until you approve it in System Settings > General > Login Items & Extensions > Network Extensions. You may also be asked to allow a VPN configuration.

The app starts the VPN by itself only when your FRITZ!Box cannot be reached, and stops it when you quit the app.

Limits:

- The Mac only rings while it is awake. With "Keep Mac awake while on power" on, it stays awake on mains power. On battery it may sleep.
- There are no push wake-ups. Calls missed while the Mac slept show up in History after it wakes.

## 8. Troubleshooting

| What you see | What to do |
|---|---|
| Red "Login rejected – check Settings" | The SIP login is wrong. Check "Phone extension user (SIP)" and the SIP password against the IP telephone's Login data tab (step 3a). Retype the password and Save. |
| Orange "Connecting…" that does not go away | Check that the Mac is on the same network as the FRITZ!Box and that the Address is right. Click Retry if offered. Away from home, see section 7. |
| Red "Offline: …" | Read the reason shown. Click Retry once the cause is fixed. |
| "Phone book unavailable (The FRITZ!Box rejected the TR-064 user name or password)" | Check the FRITZ!Box user and password, then open Settings > Diagnostics > Test TR-064 login and read the verdict. If the login is correct, check that access for applications is on (3c) and try adjusting the user's rights (3b). The app shows your saved contacts meanwhile. |
| "The FRITZ!Box certificate changed…" | You replaced or reset the box. Open Settings and click Forget pinned certificate. Do this only if you know the box was replaced. |
| No sound, or sound in one direction only | Check the microphone permission (section 5). Make sure only one softphone is signed in with that IP telephone. If two apps use the same IP telephone account, both ring and they compete for the call. |
| Keypad tones not heard | In Settings > Diagnostics, try another Keypad tone method, click Save, and test again. In-band audio is the default and the recommended one. |
| Banner only says "Notification" | Set Show Previews to Always for SIP Phone in System Settings > Notifications. |
| Settings window does not appear | The menu bar icon may be hidden (see section 2). |
| App is not in the menu bar | It may be hidden behind the notch or in your menu bar manager's overflow. Check there, or quit and start it again. |

## 9. Privacy and security

- Passwords and the WireGuard configuration are stored only in the macOS Keychain.
- The FRITZ!Box's certificate is pinned on first use. If it changes later, the app refuses to connect until you choose Forget pinned certificate.
- The contacts cache is a plain JSON file inside the app's container on your Mac. It is not encrypted.
- The app sends nothing to any server other than your FRITZ!Box (and the WireGuard peer, if you use the VPN).

## 10. Help and bug reports

For questions, bugs and feature requests, use the project repository on GitHub (see the `origin` link of this repository). For developer details, see the [README](../README.md) and [docs/MANUAL_TEST.md](MANUAL_TEST.md).
