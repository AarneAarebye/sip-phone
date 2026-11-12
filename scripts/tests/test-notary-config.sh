#!/bin/bash
# Tests for scripts/lib/notary-config.sh using synthetic dummy files in a temp directory only.
# Usage: scripts/tests/test-notary-config.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/notary-config.sh"

PASS=0; FAIL=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/notary-config-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

DUMMY_ID="ABCDE12345"
DUMMY_ISSUER="00000000-0000-0000-0000-000000000000"
DUMMY_KEY="AuthKey_TEST_ABCDE12345.p8"

new_dir() {   # fresh folder with a valid key file; prints its path
  local d; d="$(mktemp -d "$TMP/case.XXXXXX")"; chmod 700 "$d"
  printf 'dummy\n' > "$d/$DUMMY_KEY"; chmod 600 "$d/$DUMMY_KEY"
  printf '%s\n' "$d"
}
write_env() { printf '%b' "$2" > "$1/api-key.env"; chmod 600 "$1/api-key.env"; }
valid_env() { printf 'KEY_FILE=%s\nKEY_ID=%s\nISSUER=%s\n' "$DUMMY_KEY" "$DUMMY_ID" "$DUMMY_ISSUER"; }

ok()   { PASS=$((PASS+1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }

expect_ok() {   # $1 = name, $2 = dir
  local err; err="$(notary_cfg_load "$2" 2>&1)" && ok "$1" || fail "$1 (unexpected error: $err)"
}
expect_fail() {   # $1 = name, $2 = dir, $3... = secret strings that must not appear in the error output
  local name="$1" dir="$2" err s; shift 2
  err="$(notary_cfg_load "$dir" 2>&1)" && { fail "$name (expected failure)"; return; }
  [ -n "$err" ] || { fail "$name (no error message)"; return; }
  for s in "$@"; do
    case "$err" in *"$s"*) fail "$name (error message echoes a value)"; return ;; esac
  done
  ok "$name"
}

# valid file
d="$(new_dir)"; write_env "$d" "$(valid_env)"
notary_cfg_load "$d" 2>/dev/null \
  && [ "$NOTARY_KEY_PATH" = "$d/$DUMMY_KEY" ] && [ "$NOTARY_KEY_ID" = "$DUMMY_ID" ] \
  && [ "$NOTARY_ISSUER" = "$DUMMY_ISSUER" ] && [ "$NOTARY_KEY_NAME" = "$DUMMY_KEY" ] \
  && ok "valid file loads all fields" || fail "valid file loads all fields"

# missing api-key.env
d="$(new_dir)"; expect_fail "missing api-key.env" "$d"

# missing keys
for k in KEY_FILE KEY_ID ISSUER; do
  d="$(new_dir)"; write_env "$d" "$(valid_env | grep -v "^$k=")"
  expect_fail "missing $k" "$d" "$DUMMY_ID" "$DUMMY_ISSUER"
done

# bad characters in each field
d="$(new_dir)"; write_env "$d" "KEY_FILE=$DUMMY_KEY\nKEY_ID=BAD\$(touch x)ID\nISSUER=$DUMMY_ISSUER\n"
expect_fail "bad characters in KEY_ID" "$d" 'BAD' "$DUMMY_ISSUER"
d="$(new_dir)"; write_env "$d" "KEY_FILE=$DUMMY_KEY\nKEY_ID=$DUMMY_ID\nISSUER=ZZZZ-not-hex;ls\n"
expect_fail "bad characters in ISSUER" "$d" 'ZZZZ' "$DUMMY_ID"
d="$(new_dir)"; write_env "$d" "KEY_FILE=bad name;rm.p8\nKEY_ID=$DUMMY_ID\nISSUER=$DUMMY_ISSUER\n"
expect_fail "bad characters in KEY_FILE" "$d" 'bad name' "$DUMMY_ID" "$DUMMY_ISSUER"
d="$(new_dir)"; write_env "$d" "KEY_FILE=\nKEY_ID=$DUMMY_ID\nISSUER=$DUMMY_ISSUER\n"
expect_fail "empty KEY_FILE" "$d"

# path separators in KEY_FILE
d="$(new_dir)"; write_env "$d" "KEY_FILE=../$DUMMY_KEY\nKEY_ID=$DUMMY_ID\nISSUER=$DUMMY_ISSUER\n"
expect_fail "KEY_FILE with ../" "$d" "$DUMMY_ID" "$DUMMY_ISSUER"
d="$(new_dir)"; write_env "$d" "KEY_FILE=/etc/$DUMMY_KEY\nKEY_ID=$DUMMY_ID\nISSUER=$DUMMY_ISSUER\n"
expect_fail "KEY_FILE absolute path" "$d" "/etc/"

# wrong modes
d="$(new_dir)"; write_env "$d" "$(valid_env)"; chmod 644 "$d/api-key.env"
expect_fail "api-key.env mode 644" "$d" "$DUMMY_ID" "$DUMMY_ISSUER"
d="$(new_dir)"; write_env "$d" "$(valid_env)"; chmod 640 "$d/$DUMMY_KEY"
expect_fail "key file mode 640" "$d" "$DUMMY_ID" "$DUMMY_ISSUER"
d="$(new_dir)"; write_env "$d" "$(valid_env)"; chmod 604 "$d/$DUMMY_KEY"
expect_fail "key file mode 604 (other access)" "$d"
d="$(new_dir)"; write_env "$d" "$(valid_env)"; chmod 400 "$d/$DUMMY_KEY"
expect_ok "key file mode 400 accepted" "$d"

# missing KEY_FILE target
d="$(new_dir)"; write_env "$d" "$(valid_env)"; rm "$d/$DUMMY_KEY"
expect_fail "KEY_FILE target missing" "$d" "$DUMMY_ID" "$DUMMY_ISSUER"

# not a regular file
d="$(new_dir)"; write_env "$d" "$(valid_env)"; rm "$d/$DUMMY_KEY"; mkdir "$d/$DUMMY_KEY"
expect_fail "KEY_FILE target is a directory" "$d"
d="$(new_dir)"; write_env "$d" "$(valid_env)"; mv "$d/$DUMMY_KEY" "$d/real.p8"; ln -s real.p8 "$d/$DUMMY_KEY"
expect_fail "KEY_FILE target is a symlink" "$d"

# api-key.env is a dangling symlink / a directory
d="$(new_dir)"; ln -s missing-target "$d/api-key.env"
expect_fail "api-key.env dangling symlink" "$d"
d="$(new_dir)"; mkdir "$d/api-key.env"
expect_fail "api-key.env is a directory" "$d"

# comments, blank lines, quotes, whitespace, CRLF
d="$(new_dir)"; write_env "$d" "# comment KEY_ID=NOPE\n\n  KEY_FILE=\"$DUMMY_KEY\"  \nKEY_ID='$DUMMY_ID'\r\n\n# trailing\nISSUER=\"$DUMMY_ISSUER\"\n"
notary_cfg_load "$d" 2>/dev/null && [ "$NOTARY_KEY_ID" = "$DUMMY_ID" ] && [ "$NOTARY_KEY_NAME" = "$DUMMY_KEY" ] \
  && [ "$NOTARY_ISSUER" = "$DUMMY_ISSUER" ] && ok "comments, blanks, quotes, CRLF" || fail "comments, blanks, quotes, CRLF"

# unknown keys and shell code are ignored (never executed)
d="$(new_dir)"; write_env "$d" "FOO=bar\nexport KEY_ID=WRONG\n\$(touch $d/pwned)\n$(valid_env)\nEXTRA=1\n"
notary_cfg_load "$d" 2>/dev/null && [ "$NOTARY_KEY_ID" = "$DUMMY_ID" ] && [ ! -e "$d/pwned" ] \
  && ok "unknown keys ignored, nothing executed" || fail "unknown keys ignored, nothing executed"

# folder mode warning (warn only, return 0)
d="$(new_dir)"; chmod 755 "$d"
w="$(notary_cfg_dir_check "$d" 2>&1)"; rc=$?
{ [ $rc -eq 0 ] && case "$w" in *"chmod 700 ~/.config/sipphone-notary"*) true ;; *) false ;; esac; } \
  && ok "folder mode 755 warns with chmod 700 hint" || fail "folder mode 755 warns with chmod 700 hint"
real="$(new_dir)"; ln -s "$real" "$TMP/linked"
w="$(notary_cfg_dir_check "$TMP/linked" 2>&1)"
[ -z "$w" ] && ok "symlinked folder (target 700) is silent" || fail "symlinked folder (target 700) is silent"
w="$(notary_cfg_dir_check "$(new_dir)" 2>&1)"
[ -z "$w" ] && ok "folder mode 700 is silent" || fail "folder mode 700 is silent"

echo
echo "Passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
