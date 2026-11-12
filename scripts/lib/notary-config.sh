#!/bin/bash
# Safe loader for the notarytool App Store Connect API key folder (default ~/.config/sipphone-notary/).
# Meant to be sourced by scripts/release.sh and scripts/tests/test-notary-config.sh. It never sources the env file,
# never prints values from it, and reports only the NAME of the offending field or file in errors.
#
# Folder layout:
#   api-key.env   mode 600, lines KEY_FILE=<name of the .p8 in the same folder>, KEY_ID=..., ISSUER=...
#   AuthKey_*.p8  mode 600, the private key (passed to notarytool as a path, never read by these scripts)
#
# notary_cfg_load DIR  -> on success sets NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER, NOTARY_KEY_NAME and returns 0;
#                         on failure prints a message to stderr (no secret values) and returns 1.
# notary_cfg_dir_check DIR -> warns on stderr when the folder is not mode 700; always returns 0.

notary_cfg_mode() {   # $1 = path; prints the octal permission bits
  stat -L -f %Lp "$1" 2>/dev/null || stat -L -c %a "$1" 2>/dev/null
}

notary_cfg_err() { echo "ERROR: $*" >&2; }

notary_cfg_dir_check() {
  local dir="$1" m
  m="$(notary_cfg_mode "$dir")" || return 0
  if [ "$m" != "700" ]; then
    echo "WARNING: notary config folder has mode $m, expected 700. Run: chmod 700 ~/.config/sipphone-notary" >&2
  fi
  return 0
}

notary_cfg_check_file() {   # $1 = path, $2 = label (a field/file name, never a value)
  local p="$1" label="$2" m
  [ -e "$p" ] || { notary_cfg_err "$label does not exist in the notary config folder."; return 1; }
  { [ -f "$p" ] && [ ! -L "$p" ]; } || { notary_cfg_err "$label must be a regular file (not a symlink or directory)."; return 1; }
  m="$(notary_cfg_mode "$p")" || { notary_cfg_err "cannot read the permissions of $label."; return 1; }
  if [ $(( 8#$m & 8#077 )) -ne 0 ]; then
    notary_cfg_err "$label has mode $m, group/other must have no access. Run: chmod 600 \"<notary config folder>/$label\" (usually ~/.config/sipphone-notary/$label)"
    return 1
  fi
  return 0
}

notary_cfg_load() {
  local dir="$1" env="$1/api-key.env" line key val key_file="" key_id="" issuer=""
  NOTARY_KEY_PATH=""; NOTARY_KEY_ID=""; NOTARY_ISSUER=""; NOTARY_KEY_NAME=""
  notary_cfg_check_file "$env" "api-key.env" || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"       # trim leading whitespace
    line="${line%"${line##*[![:space:]]}"}"       # trim trailing whitespace
    [[ "$line" =~ ^(KEY_FILE|KEY_ID|ISSUER)= ]] || continue
    key="${line%%=*}"; val="${line#*=}"
    val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
    if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
    val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
    case "$key" in
      KEY_FILE) key_file="$val" ;;
      KEY_ID)   key_id="$val" ;;
      ISSUER)   issuer="$val" ;;
    esac
  done < "$env"

  [ -n "$key_file" ] || { notary_cfg_err "api-key.env has no KEY_FILE entry."; return 1; }
  [ -n "$key_id" ]   || { notary_cfg_err "api-key.env has no KEY_ID entry."; return 1; }
  [ -n "$issuer" ]   || { notary_cfg_err "api-key.env has no ISSUER entry."; return 1; }

  case "$key_file" in
    */*|\\*|.|..) notary_cfg_err "KEY_FILE in api-key.env must be a plain file name in the same folder (no path separators)."; return 1 ;;
  esac
  [[ "$key_file" =~ ^[A-Za-z0-9._-]+$ ]] || { notary_cfg_err "KEY_FILE in api-key.env contains characters outside [A-Za-z0-9._-]."; return 1; }
  [[ "$key_id" =~ ^[A-Za-z0-9._-]+$ ]]   || { notary_cfg_err "KEY_ID in api-key.env contains characters outside [A-Za-z0-9._-]."; return 1; }
  [[ "$issuer" =~ ^[A-Fa-f0-9-]+$ ]]     || { notary_cfg_err "ISSUER in api-key.env contains characters outside [A-Fa-f0-9-]."; return 1; }

  notary_cfg_check_file "$dir/$key_file" "the key file named by KEY_FILE" || return 1

  NOTARY_KEY_PATH="$dir/$key_file"; NOTARY_KEY_ID="$key_id"; NOTARY_ISSUER="$issuer"; NOTARY_KEY_NAME="$key_file"
  return 0
}
