#!/usr/bin/env bash
# hats — Switch between Claude Code accounts like changing hats
# https://github.com/CommanderCrowCode/hats

VERSION="0.2.3"
set -euo pipefail

# Guard: force bash to read the entire script into memory before executing,
# so a mid-session install/upgrade can't corrupt a running instance.
# shellcheck disable=SC2317
{

CLAUDE_DIR="${HATS_CLAUDE_DIR:-$HOME/.claude}"
CREDS_FILE="$CLAUDE_DIR/.credentials.json"
# Claude Code persists state (including cached identity) as a sibling of CLAUDE_DIR
STATE_FILE="${CLAUDE_DIR%/.claude}/.claude.json"
CONFIG_DIR="${HATS_CONFIG_DIR:-$HOME/.config/hats}"
VAULT_DIR="$CONFIG_DIR/vault"
LOCK_FILE="$CLAUDE_DIR/.credentials.lock"

# ── Helpers ──────────────────────────────────────────────────────

_creds_file() { echo "$CLAUDE_DIR/.credentials.${1}.json"; }
_profile_file() { echo "$CLAUDE_DIR/.profile.${1}.json"; }

_accounts() {
  for f in "$CLAUDE_DIR"/.credentials.*.json; do
    [ -f "$f" ] || continue
    local name="${f##*/.credentials.}"
    name="${name%.json}"
    echo "$name"
  done | sort
}

_default_account() {
  if [ -f "$CONFIG_DIR/default" ]; then
    cat "$CONFIG_DIR/default"
  else
    _accounts | head -1
  fi
}

_token_info() {
  local file="$1"
  python3 -c "
import json, datetime, sys
try:
    d = json.load(open('$file'))
    auth = d.get('claudeAiOauth', {})
    if not auth:
        print('error=no claudeAiOauth key')
        sys.exit(0)
    exp = datetime.datetime.fromtimestamp(auth['expiresAt'] / 1000)
    now = datetime.datetime.now()
    has_refresh = bool(auth.get('refreshToken'))
    scopes = auth.get('scopes', [])
    has_rc = 'user:sessions:claude_code' in scopes
    expired = now > exp
    print(f'expires={exp:%Y-%m-%d %H:%M}')
    print(f'refresh={has_refresh}')
    print(f'remote_control={has_rc}')
    print(f'expired={expired}')
except Exception as e:
    print(f'error={e}')
" 2>/dev/null
}

_save_profile() {
  local name="$1"
  local pfile
  pfile=$(_profile_file "$name")
  [ -f "$STATE_FILE" ] || return 0
  python3 -c "
import json, sys
try:
    state = json.load(open('$STATE_FILE'))
    profile = state.get('oauthAccount')
    if profile:
        with open('$pfile', 'w') as f:
            json.dump(profile, f)
except Exception:
    sys.exit(0)
" 2>/dev/null || true
  [ -f "$pfile" ] && chmod 600 "$pfile"
}

_restore_profile() {
  local name="$1"
  local pfile
  pfile=$(_profile_file "$name")
  [ -f "$STATE_FILE" ] || return 0
  if [ -f "$pfile" ]; then
    # Restore saved profile for this account
    python3 -c "
import json, sys
try:
    state = json.load(open('$STATE_FILE'))
    profile = json.load(open('$pfile'))
    state['oauthAccount'] = profile
    with open('$STATE_FILE', 'w') as f:
        json.dump(state, f)
except Exception:
    sys.exit(0)
" 2>/dev/null || true
  else
    # No saved profile yet — clear cached identity so Claude Code re-fetches
    python3 -c "
import json, sys
try:
    state = json.load(open('$STATE_FILE'))
    if 'oauthAccount' in state:
        del state['oauthAccount']
        with open('$STATE_FILE', 'w') as f:
            json.dump(state, f)
except Exception:
    sys.exit(0)
" 2>/dev/null || true
  fi
}

_ensure_config_dir() {
  mkdir -p "$CONFIG_DIR"
  mkdir -p "$VAULT_DIR"
}

_require_flock() {
  if ! command -v flock &>/dev/null; then
    echo "Error: flock not found. Install util-linux." >&2
    exit 1
  fi
}

_show_account_status() {
  local name="$1"
  local default="${2:-}"
  local cfile
  cfile=$(_creds_file "$name")
  local vfile="$VAULT_DIR/.credentials.${name}.json"

  local marker=" "
  [ "$name" = "$default" ] && marker="*"

  printf "  %s %-12s " "$marker" "$name"

  if [ ! -f "$cfile" ]; then
    echo "NO CREDENTIALS FILE"
    return
  fi

  local info
  info=$(_token_info "$cfile")

  if echo "$info" | grep -q "^error="; then
    echo "ERROR: $(echo "$info" | grep -oP 'error=\K.*')"
    return
  fi

  local expired has_refresh has_rc exp_date
  expired=$(echo "$info" | grep -oP 'expired=\K\w+')
  has_refresh=$(echo "$info" | grep -oP 'refresh=\K\w+')
  has_rc=$(echo "$info" | grep -oP 'remote_control=\K\w+')
  exp_date=$(echo "$info" | grep -oP 'expires=\K[^ ]+')

  local status=""
  if [ "$expired" = "True" ]; then
    if [ "$has_refresh" = "True" ]; then
      status="ok (access expired, will auto-refresh)"
    else
      status="EXPIRED (needs /login)"
    fi
  else
    status="ok (expires $exp_date)"
  fi

  [ "$has_rc" = "True" ] && status="$status [rc]" || status="$status [no-rc]"
  [ -f "$vfile" ] && status="$status [vault]"

  echo "$status"
}

# ── Commands ─────────────────────────────────────────────────────

cmd_init() {
  _ensure_config_dir

  echo "Initializing hats..."
  echo ""

  local count=0
  for name in $(_accounts); do
    echo "  Found account: $name"
    count=$((count + 1))
  done

  if [ "$count" -eq 0 ]; then
    if [ -f "$CREDS_FILE" ]; then
      echo "  Found active credentials file."
      echo ""
      echo "  To save it as a named account:"
      echo "    hats add <name>"
    else
      echo "  No credentials found."
      echo "  Run 'claude' and complete /login first, then 'hats init' again."
    fi
  else
    echo ""
    echo "  $count account(s) detected."
    local default
    default=$(_default_account)
    if [ -n "$default" ]; then
      echo "  Default account: $default"
      echo "$default" > "$CONFIG_DIR/default"
    fi
  fi

  echo ""
  echo "Config: $CONFIG_DIR"
  echo "Vault:  $VAULT_DIR"
  echo ""
  echo "Done. Run 'hats list' to see your accounts."
}

cmd_add() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    echo "Usage: hats add <name>" >&2
    echo "" >&2
    echo "Saves the current active credentials as a named account." >&2
    echo "" >&2
    echo "To add a new account:" >&2
    echo "  1. hats stash          # Save current credentials aside" >&2
    echo "  2. claude              # Start claude, run /login as new account" >&2
    echo "  3. hats add <name>    # Save new credentials" >&2
    echo "  4. hats unstash        # Restore previous credentials" >&2
    exit 1
  fi

  _ensure_config_dir

  local target
  target=$(_creds_file "$name")

  if [ -f "$target" ]; then
    echo "Account '$name' already exists." >&2
    echo "Remove it first: hats remove $name" >&2
    exit 1
  fi

  if [ ! -f "$CREDS_FILE" ]; then
    echo "Error: No active credentials at $CREDS_FILE" >&2
    echo "Run 'claude' and complete /login first." >&2
    exit 1
  fi

  cp "$CREDS_FILE" "$target"
  chmod 600 "$target"
  _save_profile "$name"
  echo "Account '$name' added."

  if [ "$(_accounts | wc -l)" -eq 1 ]; then
    echo "$name" > "$CONFIG_DIR/default"
    echo "Set as default account."
  fi

  # Warn if this account's email matches an existing account — logging in
  # as the same claude.ai user for two hats can invalidate the older session's
  # refresh token on the OAuth server.
  local new_pfile
  new_pfile=$(_profile_file "$name")
  if [ -f "$new_pfile" ]; then
    local new_email
    new_email=$(python3 -c "import json; print(json.load(open('$new_pfile')).get('emailAddress',''))" 2>/dev/null || true)
    if [ -n "$new_email" ]; then
      for existing in $(_accounts); do
        [ "$existing" = "$name" ] && continue
        local existing_pfile
        existing_pfile=$(_profile_file "$existing")
        [ -f "$existing_pfile" ] || continue
        local existing_email
        existing_email=$(python3 -c "import json; print(json.load(open('$existing_pfile')).get('emailAddress',''))" 2>/dev/null || true)
        if [ "$new_email" = "$existing_email" ]; then
          echo ""
          echo "  Warning: '$name' uses the same login ($new_email) as '$existing'."
          echo "  This new session may have invalidated '$existing's refresh token."
          echo "  Run '$existing' to verify, or re-login for '$existing' if broken."
        fi
      done
    fi
  fi

  echo ""
  _show_account_status "$name"
}

cmd_remove() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    echo "Usage: hats remove <name>" >&2
    exit 1
  fi

  local target
  target=$(_creds_file "$name")

  if [ ! -f "$target" ]; then
    echo "Account '$name' not found." >&2
    exit 1
  fi

  local default
  default=$(_default_account)
  if [ "$name" = "$default" ]; then
    echo "Warning: '$name' is the default account." >&2
    echo "Set a new default with 'hats default <name>' after removal." >&2
  fi

  rm -f "$target"
  rm -f "$(_profile_file "$name")"
  echo "Account '$name' removed."
  echo "Vault backup (if any) kept at: $VAULT_DIR/"
}

cmd_list() {
  echo "Claude Code Accounts (hats $VERSION)"
  echo "======================================"
  echo ""

  local default
  default=$(_default_account)
  local count=0

  for name in $(_accounts); do
    count=$((count + 1))
    _show_account_status "$name" "$default"
  done

  if [ "$count" -eq 0 ]; then
    echo "  No accounts found."
    echo "  Run 'hats init' to get started."
  fi

  echo ""

  if [ -f "$LOCK_FILE" ]; then
    local stale
    stale=$(find "$LOCK_FILE" -mmin +5 2>/dev/null || true)
    if [ -n "$stale" ]; then
      echo "Lock: STALE (older than 5 min) — run 'hats fix'"
    else
      echo "Lock: active"
    fi
  else
    echo "Lock: none"
  fi
}

cmd_swap() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    echo "Usage: hats swap <name> [-- claude-args...]" >&2
    exit 1
  fi
  shift

  # Handle optional -- separator
  [ "${1:-}" = "--" ] && shift

  _require_flock

  local account_creds default default_creds
  account_creds=$(_creds_file "$name")
  default=$(_default_account)
  default_creds=$(_creds_file "$default")

  if [ ! -f "$account_creds" ]; then
    echo "Error: Account '$name' not found." >&2
    echo "Available:" >&2
    _accounts | sed 's/^/  /' >&2
    exit 1
  fi

  if [ ! -f "$default_creds" ]; then
    echo "Error: Default account '$default' credentials missing." >&2
    echo "Run 'hats fix' to repair." >&2
    exit 1
  fi

  # Swap credentials under lock
  flock -w 60 "$LOCK_FILE" cp "$account_creds" "$CREDS_FILE" || {
    echo "Error: Lock timeout. Another session may be starting." >&2
    echo "Run 'hats fix' if this persists." >&2
    exit 1
  }

  # Restore target account's cached identity (or clear to force re-fetch)
  _restore_profile "$name"

  # Clear env var that would override file-based auth
  unset CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true
  [ -n "${TMUX:-}" ] && tmux setenv -u CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true

  # Run claude (foreground, interactive)
  claude "$@"
  local rc=$?

  # Save back any token refreshes Claude Code made
  if [ -f "$CREDS_FILE" ]; then
    flock -w 10 "$LOCK_FILE" cp "$CREDS_FILE" "$account_creds" 2>/dev/null || true
  fi

  # Only update cached profile on clean exit — a failed session (e.g. 401)
  # may leave stale identity in .claude.json, which would contaminate the
  # profile file for this account.
  [ "$rc" -eq 0 ] && _save_profile "$name"

  # Restore default account credentials and profile, but ONLY when swapping
  # to a non-default account. When name == default, account_creds and
  # default_creds point to the same file — the save-back above already wrote
  # to it, so reading it back here is a no-op at best. If Claude modified the
  # active file on auth failure, the save-back propagates that to default_creds,
  # and this restore would re-copy the damage into the active file with no
  # clean copy to fall back on.
  if [ "$name" != "$default" ]; then
    flock -w 10 "$LOCK_FILE" cp "$default_creds" "$CREDS_FILE" 2>/dev/null || true
    _restore_profile "$default"
  fi

  return $rc
}

cmd_backup() {
  _ensure_config_dir

  echo "Backing up credentials to vault..."
  local count=0

  for name in $(_accounts); do
    local src dst psrc pdst
    src=$(_creds_file "$name")
    dst="$VAULT_DIR/.credentials.${name}.json"
    cp "$src" "$dst"
    chmod 600 "$dst"
    psrc=$(_profile_file "$name")
    pdst="$VAULT_DIR/.profile.${name}.json"
    if [ -f "$psrc" ]; then
      cp "$psrc" "$pdst"
      chmod 600 "$pdst"
    fi
    echo "  $name: backed up"
    count=$((count + 1))
  done

  echo "Done. $count account(s) backed up to $VAULT_DIR/"
}

cmd_restore() {
  local target="${1:-}"

  if [ -z "$target" ]; then
    echo "Restoring ALL accounts from vault..."
    local count=0
    for f in "$VAULT_DIR"/.credentials.*.json; do
      [ -f "$f" ] || continue
      local name="${f##*/.credentials.}"
      name="${name%.json}"
      _restore_one "$name"
      count=$((count + 1))
    done
    echo "Done. $count account(s) restored."
  else
    _restore_one "$target"
  fi

  # Restore active file to default
  local default
  default=$(_default_account)
  local default_vault="$VAULT_DIR/.credentials.${default}.json"
  if [ -f "$default_vault" ]; then
    cp "$default_vault" "$CREDS_FILE"
    chmod 600 "$CREDS_FILE"
    echo "Active credentials set to $default."
  fi
}

_restore_one() {
  local name="$1"
  local src="$VAULT_DIR/.credentials.${name}.json"
  local dst
  dst=$(_creds_file "$name")

  if [ -f "$src" ]; then
    cp "$src" "$dst"
    chmod 600 "$dst"
    local psrc="$VAULT_DIR/.profile.${name}.json"
    local pdst
    pdst=$(_profile_file "$name")
    if [ -f "$psrc" ]; then
      cp "$psrc" "$pdst"
      chmod 600 "$pdst"
    fi
    echo "  $name: restored"
  else
    echo "  $name: FAILED (no vault backup)" >&2
  fi
}

cmd_fix() {
  echo "Repairing hats state..."
  _ensure_config_dir

  local default
  default=$(_default_account)

  if [ -z "$default" ]; then
    default=$(_accounts | head -1)
    if [ -n "$default" ]; then
      echo "$default" > "$CONFIG_DIR/default"
      echo "  Set default account: $default"
    fi
  fi

  if [ -n "$default" ]; then
    local default_creds
    default_creds=$(_creds_file "$default")
    if [ -f "$default_creds" ]; then
      cp "$default_creds" "$CREDS_FILE"
      chmod 600 "$CREDS_FILE"
      echo "  Active credentials set to $default."
    fi
  fi

  rm -f "$LOCK_FILE"
  echo "  Cleared lock file."

  # Clean up stash if left behind
  if [ -f "$CREDS_FILE.stash" ]; then
    echo "  Found stale stash — leaving in place. Run 'hats unstash' if needed."
  fi

  # ── Detect and repair credential contamination ──
  # Two accounts should never share the same refresh token.
  local dup_creds
  dup_creds=$(python3 -c "
import json, os, sys
claude_dir = os.environ.get('HATS_CLAUDE_DIR', os.path.expanduser('~/.claude'))
tokens = {}
for f in sorted(os.listdir(claude_dir)):
    if not f.startswith('.credentials.') or not f.endswith('.json'):
        continue
    if f == '.credentials.json':
        continue
    name = f[len('.credentials.'):-len('.json')]
    try:
        d = json.load(open(os.path.join(claude_dir, f)))
        rt = d.get('claudeAiOauth', {}).get('refreshToken', '')
        if rt:
            tokens.setdefault(rt, []).append(name)
    except Exception:
        pass
dupes = {rt: names for rt, names in tokens.items() if len(names) > 1}
if dupes:
    for rt, names in dupes.items():
        print(','.join(names))
" 2>/dev/null || true)

  if [ -n "$dup_creds" ]; then
    echo ""
    echo "  ⚠ Credential contamination detected!"
    echo "    These accounts share identical tokens:"
    while IFS= read -r group; do
      echo "      ${group//,/ ↔ }"
    done <<< "$dup_creds"
    # Try to restore from vault
    local restored_any=false
    while IFS= read -r group; do
      IFS=',' read -ra names <<< "$group"
      for name in "${names[@]}"; do
        local vault_file="$VAULT_DIR/.credentials.${name}.json"
        local creds_file
        creds_file=$(_creds_file "$name")
        if [ -f "$vault_file" ]; then
          local vault_rt current_rt
          vault_rt=$(python3 -c "import json; print(json.load(open('$vault_file')).get('claudeAiOauth',{}).get('refreshToken',''))" 2>/dev/null || true)
          current_rt=$(python3 -c "import json; print(json.load(open('$creds_file')).get('claudeAiOauth',{}).get('refreshToken',''))" 2>/dev/null || true)
          if [ -n "$vault_rt" ] && [ "$vault_rt" != "$current_rt" ]; then
            cp "$vault_file" "$creds_file"
            chmod 600 "$creds_file"
            echo "    Restored '$name' credentials from vault."
            restored_any=true
          fi
        fi
      done
    done <<< "$dup_creds"
    if [ "$restored_any" = false ]; then
      echo "    No vault backups with different tokens found."
      echo "    You may need to re-login: hats remove <name> && hats add <name>"
    fi
  fi

  # ── Detect and repair profile contamination ──
  # If multiple accounts have the same cached email, clear profiles to force re-fetch.
  local dup_profiles
  dup_profiles=$(python3 -c "
import json, os, sys
claude_dir = os.environ.get('HATS_CLAUDE_DIR', os.path.expanduser('~/.claude'))
emails = {}
for f in sorted(os.listdir(claude_dir)):
    if not f.startswith('.profile.') or not f.endswith('.json'):
        continue
    name = f[len('.profile.'):-len('.json')]
    try:
        d = json.load(open(os.path.join(claude_dir, f)))
        email = d.get('emailAddress', '')
        if email:
            emails.setdefault(email, []).append(name)
    except Exception:
        pass
dupes = {email: names for email, names in emails.items() if len(names) > 1}
if dupes:
    for email, names in dupes.items():
        print(f'{email}:{\"|\".join(names)}')
" 2>/dev/null || true)

  if [ -n "$dup_profiles" ]; then
    echo ""
    echo "  ⚠ Profile contamination detected!"
    while IFS= read -r line; do
      local email="${line%%:*}"
      local name_list="${line#*:}"
      echo "    Same identity ($email) cached for: ${name_list//|/, }"
      IFS='|' read -ra names <<< "$name_list"
      for name in "${names[@]}"; do
        local pfile
        pfile=$(_profile_file "$name")
        rm -f "$pfile"
      done
    done <<< "$dup_profiles"
    echo "    Cleared affected profiles — correct identity will be fetched on next swap."
  fi

  # Restore default profile (after contamination cleanup)
  if [ -n "$default" ]; then
    _restore_profile "$default"
    echo "  Profile restored to $default."
  fi

  echo "Done. Run 'hats list' to verify."
}

cmd_default() {
  local name="${1:-}"

  if [ -z "$name" ]; then
    echo "Default account: $(_default_account)"
    return
  fi

  local creds
  creds=$(_creds_file "$name")
  if [ ! -f "$creds" ]; then
    echo "Error: Account '$name' not found." >&2
    exit 1
  fi

  _ensure_config_dir
  echo "$name" > "$CONFIG_DIR/default"
  echo "Default account set to '$name'."
}

cmd_stash() {
  if [ ! -f "$CREDS_FILE" ]; then
    echo "No active credentials to stash."
    return
  fi

  cp "$CREDS_FILE" "$CREDS_FILE.stash"
  rm "$CREDS_FILE"
  echo "Credentials stashed."
  echo "Run 'claude' to log in as a new account."
  echo "After login: 'hats add <name>' then 'hats unstash'."
}

cmd_unstash() {
  if [ ! -f "$CREDS_FILE.stash" ]; then
    echo "No stashed credentials found." >&2
    exit 1
  fi

  mv "$CREDS_FILE.stash" "$CREDS_FILE"
  chmod 600 "$CREDS_FILE"
  echo "Credentials restored from stash."
}

cmd_shell_init() {
  local extra_args=""
  for arg in "$@"; do
    case "$arg" in
      --skip-permissions) extra_args=" --dangerously-skip-permissions" ;;
    esac
  done

  cat <<'HEADER'
# Generated by hats shell-init
# Add to your shell config:
#   eval "$(hats shell-init)"
#   eval "$(hats shell-init --skip-permissions)"  # to auto-skip permission prompts

HEADER

  for name in $(_accounts); do
    echo "${name}() { hats swap ${name}${extra_args} -- \"\$@\"; }"
  done
}

cmd_version() {
  echo "hats $VERSION"
}

# ── Main ─────────────────────────────────────────────────────────

case "${1:-}" in
  init)             cmd_init ;;
  add)              cmd_add "${2:-}" ;;
  remove|rm)        cmd_remove "${2:-}" ;;
  list|ls|status)   cmd_list ;;
  swap)             shift; cmd_swap "$@" ;;
  backup)           cmd_backup ;;
  restore)          cmd_restore "${2:-}" ;;
  fix)              cmd_fix ;;
  default)          cmd_default "${2:-}" ;;
  stash)            cmd_stash ;;
  unstash)          cmd_unstash ;;
  shell-init)       shift; cmd_shell_init "$@" ;;
  version|-v|--version) cmd_version ;;
  help|-h|--help|"")
    cat <<EOF
hats $VERSION — Switch between Claude Code accounts

Usage: hats <command> [args]

Account Management:
  init                 Initialize hats, detect existing accounts
  add <name>           Save current credentials as a named account
  remove <name>        Remove an account
  default [name]       Get or set the default account
  list                 Show all accounts and token status

Session Management:
  swap <name> [args]   Switch to account and run claude

Credential Safety:
  backup               Backup all credentials to vault
  restore [name]       Restore from vault (all or one)
  stash                Temporarily set aside active credentials
  unstash              Restore stashed credentials
  fix                  Repair state, detect contamination, restore vault

Shell Integration:
  shell-init           Output shell functions for .zshrc/.bashrc
                       Use: eval "\$(hats shell-init)"
                       Flags: --skip-permissions

  version              Show version

Environment Variables:
  HATS_CLAUDE_DIR      Claude config directory (default: ~/.claude)
  HATS_CONFIG_DIR      Hats config directory (default: ~/.config/hats)

Config: $CONFIG_DIR
Vault:  $VAULT_DIR
EOF
    ;;
  *)
    echo "Unknown command: $1" >&2
    echo "Run 'hats help' for usage." >&2
    exit 1
    ;;
esac
exit
}
