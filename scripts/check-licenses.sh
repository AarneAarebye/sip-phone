#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright © 2026 Aarne Aarebye
# Checks the licence files: LICENSE is the full GPL-3.0 text, THIRD_PARTY_LICENSES.md names every component in
# scripts/third-party-components.txt, and (given an app path) the built app bundles both files as resources.
# Usage: scripts/check-licenses.sh [path/to/SipPhone.app]     (bash 3.2 compatible)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LICENSE="$ROOT/LICENSE"
TPL="$ROOT/THIRD_PARTY_LICENSES.md"
MANIFEST="$ROOT/scripts/third-party-components.txt"
fail=0
err() { echo "FAIL: $*" >&2; fail=1; }

check_license() {   # $1 = LICENSE path
  [ -f "$1" ] || { err "$1 is missing"; return; }
  head -2 "$1" | grep -q 'GNU GENERAL PUBLIC LICENSE' || err "$1 does not start with the GPL title"
  head -2 "$1" | grep -q 'Version 3, 29 June 2007' || err "$1 is not GPL version 3"
  local n; n=$(wc -l < "$1" | tr -d ' ')
  [ "$n" -ge 670 ] || err "$1 looks truncated ($n lines, expected about 674)"
  grep -q 'END OF TERMS AND CONDITIONS' "$1" || err "$1 lacks 'END OF TERMS AND CONDITIONS'"
}

check_license "$LICENSE"
[ -f "$MANIFEST" ] || err "$MANIFEST is missing"
if [ -f "$TPL" ]; then
  count=0
  while IFS= read -r name || [ -n "$name" ]; do
    case "$name" in ''|'#'*) continue ;; esac
    count=$((count + 1))
    grep -qF -- "$name" "$TPL" || err "THIRD_PARTY_LICENSES.md does not mention '$name'"
  done < "$MANIFEST"
  [ "$count" -gt 0 ] || err "the component manifest is empty"
  grep -q 'https://github.com/AarneAarebye/sip-phone' "$TPL" || err "THIRD_PARTY_LICENSES.md lacks the offer of source"
else
  err "$TPL is missing"
fi

if [ $# -ge 1 ]; then
  RES="$1/Contents/Resources"
  [ -d "$RES" ] || err "$RES does not exist"
  check_license "$RES/LICENSE"
  if [ -f "$RES/THIRD_PARTY_LICENSES.md" ]; then
    cmp -s "$TPL" "$RES/THIRD_PARTY_LICENSES.md" || err "the bundled THIRD_PARTY_LICENSES.md differs from the repository copy"
  else
    err "$RES/THIRD_PARTY_LICENSES.md is missing"
  fi
fi

if [ "$fail" -eq 0 ]; then echo "check-licenses: OK"; else echo "check-licenses: FAILED" >&2; fi
exit "$fail"
