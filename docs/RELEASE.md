# Releasing SIP Phone

`scripts/release.sh` produces a universal (arm64 + x86_64), Developer ID signed, notarized and stapled `build/release/SipPhone.dmg` (the app inside and the DMG itself are both signed, notarized and stapled). The app is distributed outside the Mac App Store; the embedded WireGuard packet tunnel is a system extension, which requires Developer ID provisioning profiles.

## One-time prerequisites

### Certificate

A "Developer ID Application" certificate for team `LKF7C4WS72` in the login keychain, with its private key. Create it at developer.apple.com > Certificates, or in Xcode > Settings > Accounts > Manage Certificates. Check:

```
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### App IDs

At developer.apple.com > Identifiers, two explicit App IDs:

| Bundle id | Capabilities |
|---|---|
| `com.aarneaarebye.sipphone` | Network Extensions, System Extension, App Groups |
| `com.aarneaarebye.sipphone.PacketTunnel` | Network Extensions, App Groups |

Both entitlement files use the app group `LKF7C4WS72.com.aarneaarebye.sipphone` (team-prefixed macOS form, resolved from `$(TeamIdentifierPrefix)`). If the portal or the profile requires an explicit group, register that id and assign it to both App IDs.

### Provisioning profiles

At developer.apple.com > Profiles, create two profiles of type "Developer ID" (distribution outside the Mac App Store), one per App ID, with exactly these names (they are referenced from `project.yml` and `scripts/release.sh`):

| App ID | Profile name |
|---|---|
| `com.aarneaarebye.sipphone` | `SipPhone Developer ID` |
| `com.aarneaarebye.sipphone.PacketTunnel` | `SipPhone PacketTunnel Developer ID` |

Download both `.provisionprofile` files and double-click each to install them (Xcode copies them to `~/Library/Developer/Xcode/UserData/Provisioning Profiles`). If you pick different names, change `PROVISIONING_PROFILE_SPECIFIER` in the Release configs of both targets in `project.yml` and `APP_PROFILE` / `EXT_PROFILE` in `scripts/release.sh`.

### Notarization credentials

`scripts/release.sh` authenticates `notarytool` with an App Store Connect API key kept outside the repository in `~/.config/apple-api/` (override the folder with the environment variable `SIPPHONE_NOTARY_DIR`):

```
~/.config/apple-api/            mode 700
  api-key.env                         mode 600
  AuthKey_<NAME>_<KEYID>.p8           mode 600, the private key
```

`api-key.env` holds three `KEY=VALUE` lines (quotes, blank lines and `#` comments are allowed; other keys are ignored):

```
# KEY_FILE: file name in the same folder, no path separators
KEY_FILE=AuthKey_<NAME>_<KEYID>.p8
# KEY_ID: letters, digits, . _ -
KEY_ID=<key id>
# ISSUER: the UUID shown on the App Store Connect Keys page
ISSUER=<issuer id>
```

Format rules: one `KEY=value` per line, no spaces around `=`, no `export`, no inline comments (a comment must be on its own line starting with `#`), single or double quotes around the value are allowed, the last duplicate wins, and a UTF-8 BOM on the first line is not supported.

The script reads only these three keys with a small parser; it never `source`s the file, never prints the values, and passes the key to `notarytool` as a file path (`--key`, `--key-id`, `--issuer`), so the private key never appears on a command line or in output. The key id and issuer are identifiers, not secrets, but they are visible to local users in `ps` while `notarytool` runs; the script itself never prints them or the key file name. It stops with a `chmod 600` hint if `api-key.env` or the key file is missing, not a regular file, or accessible by group or others, and warns (does not stop) when the folder is not mode 700 (`chmod 700 ~/.config/apple-api`).

The API key needs the Developer role or higher (App Store Connect > Users and Access > Integrations > Team Keys); such a key can notarize. The folder must never be committed. It lives outside the repo, and nothing in the repository references the key id, issuer or key file.

Tests for the parser and permission checks use synthetic files in a temp directory: `scripts/tests/test-notary-config.sh`.

Fallback: if `api-key.env` does not exist in that folder, the script uses the notarytool Keychain profile `sipphone-notary` instead (a Keychain item, not a folder). Create it once with an app-specific password from account.apple.com (the command prompts for it; nothing is written to the repository):

```
xcrun notarytool store-credentials "sipphone-notary" --apple-id <apple id> --team-id LKF7C4WS72
```

`--unsigned` and `--skip-notarize` need neither.

### Tools

Xcode, `brew install xcodegen go`. The script builds `Packages/PhoneKit/Frameworks/PJSIP.xcframework` with `scripts/build-pjsip.sh` if it is missing.

## Running the script

```
scripts/release.sh                    # full run: archive, export, verify, notarize, staple, DMG, final checks
scripts/release.sh --skip-notarize    # signed and verified, builds a signed DMG, no notarization or stapling
scripts/release.sh --unsigned         # dry run, see below
```

Output is under `build/release/` (git-ignored): `SipPhone.xcarchive`, `ExportOptions.plist` (generated), `export/SipPhone.app`, `SipPhone.dmg`.

The script stops with a message if the certificate, either profile, the notary credentials, `xcodegen` or `go` is missing. Steps of a full run:

1. build PJSIP if needed, `xcodegen`
2. `xcodebuild archive` (Release, `ARCHS = arm64 x86_64`, hardened runtime, manual signing)
3. `xcodebuild -exportArchive` with method `developer-id`, signing style manual, both profiles mapped
4. `codesign --verify --deep --strict --verbose=2`; checks hardened runtime, Developer ID authority, team id and the Network Extension, System Extension, and audio-input entitlements
5. `lipo -archs` of the app and extension executables must include arm64 and x86_64
6. zip with `ditto`, `notarytool submit --wait` (on rejection the script prints `notarytool log`), `stapler staple` the app
7. DMG with `ditto` staging and `hdiutil`, `codesign --timestamp` with the Developer ID Application identity resolved in the prerequisite check, then notarize (`notarytool submit --wait`, log on failure) and `stapler staple` the DMG
8. final checks: `spctl -a -t exec -vv` and `stapler validate` on the app, `spctl -a -t open --context context:primary-signature -vv` and `stapler validate` on the DMG (all hard failures)

Signature verification also requires a secure timestamp (`Timestamp=` in `codesign -dvv`) on the app, the extension and the DMG; the Release configuration sets `OTHER_CODE_SIGN_FLAGS = --timestamp` for both targets. With `--skip-notarize` the script ends after step 7's signing and says the DMG is signed but not notarized or stapled; such a DMG is rejected by Gatekeeper on other Macs. Expired provisioning profiles are skipped with a warning during the prerequisite check.

### Unsigned dry run

`--unsigned` archives with `CODE_SIGNING_ALLOWED=NO` and checks that the app and the extension are universal, then stops. It needs no certificate, profiles or notary credentials, exports nothing and builds no DMG. The archive is unsigned: it cannot activate the system extension and must not be distributed. The same applies to `xcodebuild ... CODE_SIGNING_ALLOWED=NO build`, which also works for the Release configuration.

## First run on a target Mac

1. Copy `SipPhone.dmg` to the Mac, open it and drag SIP Phone to Applications. Run it from `/Applications`: system extensions can only be activated from there.
2. When the VPN is first needed (or on start), macOS shows "System Extension Blocked". Open System Settings > General > Login Items & Extensions > Network Extensions (on some versions Privacy & Security) and enable the SIP Phone VPN extension; authenticate when asked.
3. macOS then asks to allow a VPN configuration; allow it.
4. Allow microphone access on the first call.

Check state: `systemextensionsctl list` should show `com.aarneaarebye.sipphone.PacketTunnel` as `[activated enabled]`.

## Testing on the Intel iMac (macOS Tahoe 26)

macOS 26 Tahoe is the last macOS release that supports Intel Macs. The app deploys to macOS 14 and the binaries contain both slices, so the same DMG is used.

1. Copy the DMG over (AirDrop or a USB stick). Gatekeeper checks the notarization ticket, which is stapled, so it works offline.
2. Install, approve the extension as above, then follow `docs/MANUAL_TEST.md`.
3. Confirm the slice in use: `lipo -archs /Applications/SipPhone.app/Contents/MacOS/SipPhone` lists `x86_64 arm64`; `file` on the extension executable shows both architectures too.

## Troubleshooting

- "Provisioning profile ... doesn't include the ... entitlement" or "profile doesn't match bundle identifier": the profile was created for the wrong App ID, or the App ID lacks Network Extensions / System Extension. Fix the App ID, regenerate and reinstall the profile, and keep its name. Inspect an installed profile: `security cms -D -i <file>.provisionprofile`.
- "No profile matching 'SipPhone Developer ID' found": the name differs from the one in `project.yml`, or the profile is of a different type (it must be Developer ID, not Development).
- "System extension not found inside the app": the extension must be at `Contents/Library/SystemExtensions/com.aarneaarebye.sipphone.PacketTunnel.systemextension`. It comes from the `PacketTunnel` dependency of the app target in `project.yml`; `PRODUCT_NAME` of the extension must be its bundle id.
- Notarization rejected: the script prints the log. Common causes are a missing hardened runtime, a missing secure timestamp, or an unsigned nested binary. Fetch it again with `xcrun notarytool log <submission id>` with the same credential flags as the script (`--key <path to the .p8> --key-id <id> --issuer <issuer>`, or `--keychain-profile sipphone-notary` for the fallback); the ids are listed by `xcrun notarytool history` with the same flags.
- `notarytool history` fails in the prerequisite check: the API key may be revoked, have too low a role, or `KEY_ID` / `ISSUER` may be wrong; for the keychain fallback re-run `store-credentials` (the app-specific password may have been revoked).
- "api-key.env ... group/other must have no access": `chmod 600` the file named in the message (and the `.p8`); `chmod 700 ~/.config/apple-api`.
- Extension stays "waiting for user approval" or never appears: it is only activated for an app in `/Applications`; check `systemextensionsctl list` and the approval in System Settings.
- Go build fails inside Xcode: make sure `go` is on the path that Xcode sees (`/opt/homebrew/bin` on Apple Silicon, `/usr/local/bin` on Intel); run the script from a shell where `go version` works.

## Status

The unsigned dry run and the unsigned Debug and Release builds are verified. A full signed, notarized run needs the certificate, profiles and notary credentials above and has not been performed yet; the signing, notarization, stapling and DMG steps are therefore untested.
