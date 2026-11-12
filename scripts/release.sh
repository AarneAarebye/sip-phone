#!/bin/bash
# Builds a universal, Developer ID signed, notarized and stapled FritzPhone.dmg under build/release/.
# See docs/RELEASE.md for the one-time prerequisites. The script holds no credentials: notarization uses the
# notarytool keychain profile "fritzphone-notary" created by the user with `xcrun notarytool store-credentials`.
#
# Usage: scripts/release.sh [--unsigned] [--skip-notarize] [--help]
#   --unsigned       Dry run: archive with CODE_SIGNING_ALLOWED=NO, check the app and extension are universal, stop.
#                    Needs no certificate, profiles or notary profile. Produces no exported app and no DMG, and the
#                    result must NOT be distributed (it is unsigned, so the system extension cannot be activated).
#   --skip-notarize  Sign and export, verify signatures and architectures, but do not notarize, staple or build the DMG.
set -euo pipefail

TEAM_ID="LKF7C4WS72"
APP_NAME="FritzPhone"
APP_BUNDLE_ID="com.aarneaarebye.fritzphone"
EXT_BUNDLE_ID="com.aarneaarebye.fritzphone.PacketTunnel"
APP_PROFILE="FritzPhone Developer ID"                  # must match project.yml
EXT_PROFILE="FritzPhone PacketTunnel Developer ID"     # must match project.yml
NOTARY_PROFILE="fritzphone-notary"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
ARCHIVE="$OUT/$APP_NAME.xcarchive"
EXPORT="$OUT/export"
APP="$EXPORT/$APP_NAME.app"
DMG="$OUT/$APP_NAME.dmg"

UNSIGNED=0
SKIP_NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --unsigned) UNSIGNED=1 ;;
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
  esac
done

step() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found. $2"; }

check_archs() {   # $1 = label, $2 = executable path; must contain arm64 and x86_64
  [ -f "$2" ] || die "$1 executable not found at $2"
  local archs; archs="$(lipo -archs "$2")"
  echo "$1: $archs"
  case " $archs " in *" arm64 "*) ;; *) die "$1 lacks arm64 (has: $archs)" ;; esac
  case " $archs " in *" x86_64 "*) ;; *) die "$1 lacks x86_64 (has: $archs)" ;; esac
}

# ---- prerequisites -------------------------------------------------------------------------------------------
step "Checking prerequisites"
need xcodebuild "Install Xcode."
need xcodegen "brew install xcodegen"
need go "brew install go (the WireGuard Go bridge is built with it)"
need lipo "Install the Xcode command line tools."
if [ "$UNSIGNED" -eq 0 ]; then
  need codesign "Install the Xcode command line tools."
  need hdiutil "macOS tool missing?"
  need security "macOS tool missing?"
  security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($TEAM_ID)" \
    || die "No 'Developer ID Application' certificate for team $TEAM_ID in the keychain (see docs/RELEASE.md, 'Certificate')."

  profile_names=""
  for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.provisionprofile "$dir"/*.mobileprovision; do
      [ -f "$f" ] || continue
      n="$(security cms -D -i "$f" 2>/dev/null | /usr/libexec/PlistBuddy -c 'Print :Name' /dev/stdin 2>/dev/null || true)"
      profile_names="$profile_names"$'\n'"$n"
    done
  done
  for name in "$APP_PROFILE" "$EXT_PROFILE"; do
    printf '%s\n' "$profile_names" | grep -qxF "$name" \
      || die "Provisioning profile named '$name' is not installed (see docs/RELEASE.md, 'Provisioning profiles'). Double-click the downloaded .provisionprofile to install it."
  done

  if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
      || die "notarytool keychain profile '$NOTARY_PROFILE' is missing or invalid. Create it once with: xcrun notarytool store-credentials \"$NOTARY_PROFILE\" (see docs/RELEASE.md)."
  fi
fi

# ---- build inputs --------------------------------------------------------------------------------------------
cd "$ROOT"
if [ ! -d "$ROOT/Packages/PhoneKit/Frameworks/PJSIP.xcframework" ]; then
  step "Building PJSIP xcframework (missing)"
  "$ROOT/scripts/build-pjsip.sh"
fi

step "Generating Xcode project"
xcodegen

rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p "$OUT"

# ---- archive -------------------------------------------------------------------------------------------------
step "Archiving (Release, arm64 + x86_64)"
if [ "$UNSIGNED" -eq 1 ]; then
  xcodebuild archive -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" CODE_SIGNING_ALLOWED=NO
  ARCHIVED_APP="$ARCHIVE/Products/Applications/$APP_NAME.app"
  EXT="$ARCHIVED_APP/Contents/Library/SystemExtensions/$EXT_BUNDLE_ID.systemextension"
  [ -d "$EXT" ] || die "System extension not found in the archived app at $EXT"
  step "Checking architectures"
  check_archs "app" "$ARCHIVED_APP/Contents/MacOS/$APP_NAME"
  check_archs "extension" "$EXT/Contents/MacOS/$EXT_BUNDLE_ID"
  echo
  echo "Unsigned dry run OK. Archive: $ARCHIVE (unsigned, do not distribute)."
  exit 0
fi

xcodebuild archive -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE"

# ---- export --------------------------------------------------------------------------------------------------
step "Exporting with Developer ID"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>$APP_BUNDLE_ID</key>
		<string>$APP_PROFILE</string>
		<key>$EXT_BUNDLE_ID</key>
		<string>$EXT_PROFILE</string>
	</dict>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$EXPORT"

EXT="$APP/Contents/Library/SystemExtensions/$EXT_BUNDLE_ID.systemextension"
[ -d "$APP" ] || die "Exported app not found at $APP"
[ -d "$EXT" ] || die "System extension not found inside the app at $EXT (check the embed settings in project.yml)."

# ---- verify signatures, hardened runtime, entitlements, architectures ------------------------------------------
step "Verifying signatures"
codesign --verify --deep --strict --verbose=2 "$APP"
for bundle in "$APP" "$EXT"; do
  info="$(codesign -dvv "$bundle" 2>&1)"
  printf '%s\n' "$info" | grep -q "flags=.*runtime" || die "Hardened runtime is not enabled on $bundle"
  printf '%s\n' "$info" | grep -q "Authority=Developer ID Application" || die "$bundle is not signed with a Developer ID Application certificate"
  printf '%s\n' "$info" | grep -q "TeamIdentifier=$TEAM_ID" || die "$bundle has an unexpected team identifier"
  ents="$(codesign -d --entitlements - "$bundle" 2>/dev/null || true)"
  printf '%s\n' "$ents" | grep -q "com.apple.developer.networking.networkextension" || die "Network Extension entitlement missing on $bundle"
done
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.developer.system-extension.install" \
  || die "System Extension install entitlement missing on the app"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "com.apple.security.device.audio-input" \
  || die "Audio input entitlement missing on the app"

step "Checking architectures"
check_archs "app" "$APP/Contents/MacOS/$APP_NAME"
check_archs "extension" "$EXT/Contents/MacOS/$EXT_BUNDLE_ID"

if [ "$SKIP_NOTARIZE" -eq 1 ]; then
  echo
  echo "Signed and verified (notarization skipped): $APP"
  exit 0
fi

# ---- notarize ------------------------------------------------------------------------------------------------
step "Notarizing (this can take several minutes)"
ZIP="$OUT/$APP_NAME-notarize.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SUBMIT_OUT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
printf '%s\n' "$SUBMIT_OUT"
if ! printf '%s\n' "$SUBMIT_OUT" | grep -q "status: Accepted"; then
  SUB_ID="$(printf '%s\n' "$SUBMIT_OUT" | awk '/^ *id:/ {print $2; exit}')"
  if [ -n "$SUB_ID" ]; then
    echo "--- notarization log ---" >&2
    xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
  fi
  die "Notarization was not accepted."
fi
rm -f "$ZIP"

step "Stapling"
xcrun stapler staple "$APP"

# ---- DMG -----------------------------------------------------------------------------------------------------
step "Building DMG"
STAGE="$OUT/dmg-stage"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

# ---- final checks --------------------------------------------------------------------------------------------
step "Final verification"
spctl -a -t exec -vv "$APP"
xcrun stapler validate "$APP"
xcrun stapler validate "$DMG" 2>/dev/null || echo "Note: the DMG itself is not stapled; the app inside is."
check_archs "app" "$APP/Contents/MacOS/$APP_NAME"
check_archs "extension" "$EXT/Contents/MacOS/$EXT_BUNDLE_ID"

echo
echo "Done: $DMG"
