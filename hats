#!/usr/bin/env bash
# hats — Switch between Claude Code accounts like changing hats
# https://github.com/CommanderCrowCode/hats

VERSION="1.0.0"
set -euo pipefail

# Guard: force bash to read the entire script into memory before executing,
# so a mid-session install/upgrade can't corrupt a running instance.
# shellcheck disable=SC2317
{

HATS_DIR="${HATS_DIR:-$HOME/.hats}"
HATS_CLAUDE_DIR="$HATS_DIR/claude"
HATS_BASE_DIR="$HATS_CLAUDE_DIR/base"
HATS_CONFIG="$HATS_DIR/config.toml"

# These files are ALWAYS per-account, never symlinked to base
ALWAYS_ISOLATED=(".credentials.json" ".claude.json")

# ── Helpers ──────────────────────────────────────────────────────

die() { echo "Error: $*" >&2; exit 1; }

_is_isolated() {
  local resource="$1"
  for f in "${ALWAYS_ISOLATED[@]}"; do
    [ "$f" = "$resource" ] && return 0
  done
  return 1
}

_validate_name() {
  local name="$1"
  [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die "Invalid account name '$name'. Use alphanumeric, dots, hyphens, underscores."
  [ "$name" = "base" ] && die "'base' is reserved for the template directory."
}

_accounts() {
  [ -d "$HATS_CLAUDE_DIR" ] || return 0
  for d in "$HATS_CLAUDE_DIR"/*/; do
    [ -d "$d" ] || continue
    local name
    name=$(basename "$d")
    [ "$name" = "base" ] && continue
    echo "$name"
  done | sort
}

_account_dir() { echo "$HATS_CLAUDE_DIR/$1"; }

_account_exists() { [ -d "$(_account_dir "$1")" ]; }

_default_account() {
  if [ -f "$HATS_CONFIG" ]; then
    local val
    val=$(grep -A5 '^\[hats\]' "$HATS_CONFIG" 2>/dev/null | grep '^default' | head -1 | sed 's/.*=\s*"\?\([^"]*\)"\?/\1/' | tr -d '[:space:]')
    [ -n "$val" ] && echo "$val" && return
  fi
  _accounts | head -1
}

_set_default() {
  local name="$1"
  if [ -f "$HATS_CONFIG" ]; then
    # Update existing default line
    if grep -q '^default' "$HATS_CONFIG" 2>/dev/null; then
      sed -i "s/^default.*/default = \"$name\"/" "$HATS_CONFIG"
    else
      sed -i "/^\[hats\]/a default = \"$name\"" "$HATS_CONFIG"
    fi
  else
    mkdir -p "$HATS_DIR"
    cat > "$HATS_CONFIG" <<EOF
[hats]
version = "$VERSION"
default = "$name"
EOF
  fi
  # Update ~/.claude symlink
  ln -sfn "$HATS_CLAUDE_DIR/$name" "$HOME/.claude"
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

_show_account_status() {
  local name="$1"
  local default="${2:-}"
  local cfile="$(_account_dir "$name")/.credentials.json"

  local marker=" "
  [ "$name" = "$default" ] && marker="*"

  printf "  %s %-12s " "$marker" "$name"

  if [ ! -f "$cfile" ]; then
    echo "NO CREDENTIALS"
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

  echo "$status"
}

# ── Symlink Engine ───────────────────────────────────────────────

_setup_account_dir() {
  local name="$1"
  local acct_dir
  acct_dir=$(_account_dir "$name")

  mkdir -p "$acct_dir"

  # Create symlinks for everything in base except always-isolated files
  for item in "$HATS_BASE_DIR"/*  "$HATS_BASE_DIR"/.*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    local basename
    basename=$(basename "$item")

    # Skip . and ..
    [[ "$basename" == "." || "$basename" == ".." ]] && continue

    # Skip always-isolated files
    _is_isolated "$basename" && continue

    # Skip if already exists in account dir
    [ -e "$acct_dir/$basename" ] || [ -L "$acct_dir/$basename" ] && continue

    ln -s "../base/$basename" "$acct_dir/$basename"
  done

  # Create isolated files
  [ -f "$acct_dir/.claude.json" ] || echo '{}' > "$acct_dir/.claude.json"
}

_link_resource() {
  local name="$1" resource="$2"
  local acct_dir
  acct_dir=$(_account_dir "$name")

  _is_isolated "$resource" && die "'$resource' is always isolated and cannot be linked."

  # Check resource exists in base
  [ -e "$HATS_BASE_DIR/$resource" ] || [ -L "$HATS_BASE_DIR/$resource" ] || \
    die "Resource '$resource' not found in base."

  # Check not already linked
  if [ -L "$acct_dir/$resource" ]; then
    local target
    target=$(readlink "$acct_dir/$resource")
    [[ "$target" == *"base/$resource"* ]] && die "'$resource' is already linked to base."
  fi

  # Remove local copy and create symlink
  rm -rf "$acct_dir/$resource"
  ln -s "../base/$resource" "$acct_dir/$resource"
  echo "Linked $name/$resource -> base/$resource"
}

_unlink_resource() {
  local name="$1" resource="$2"
  local acct_dir
  acct_dir=$(_account_dir "$name")

  _is_isolated "$resource" && die "'$resource' is always isolated."

  # Check resource is currently a symlink
  [ -L "$acct_dir/$resource" ] || die "'$resource' is already isolated for '$name'."

  # Resolve and copy
  local real_path
  real_path=$(realpath "$acct_dir/$resource")

  rm "$acct_dir/$resource"
  if [ -d "$real_path" ]; then
    cp -a "$real_path" "$acct_dir/$resource"
  else
    cp -a "$real_path" "$acct_dir/$resource"
  fi

  echo "Unlinked $name/$resource (now isolated)"
}

_is_linked() {
  local name="$1" resource="$2"
  local acct_dir
  acct_dir=$(_account_dir "$name")

  if [ -L "$acct_dir/$resource" ]; then
    local target
    target=$(readlink "$acct_dir/$resource")
    [[ "$target" == *"base/"* ]] && return 0
  fi
  return 1
}

# ── Commands ─────────────────────────────────────────────────────

cmd_init() {
  if [ -d "$HATS_DIR" ] && [ -f "$HATS_CONFIG" ]; then
    echo "hats is already initialized at $HATS_DIR"
    echo ""
    echo "Accounts:"
    for name in $(_accounts); do
      echo "  $name -> $(_account_dir "$name")"
    done
    echo ""
    echo "Default: $(_default_account)"
    return
  fi

  echo "Initializing hats v$VERSION..."
  echo ""

  # Detect existing ~/.claude/ setup
  local claude_dir="$HOME/.claude"

  # If ~/.claude is already a symlink, detect previous hats setup
  if [ -L "$claude_dir" ]; then
    die "~/.claude is already a symlink ($(readlink "$claude_dir")). Remove it first or check if hats is already set up."
  fi

  mkdir -p "$HATS_CLAUDE_DIR"

  if [ -d "$claude_dir" ]; then
    echo "  Found existing ~/.claude/ directory"
    echo "  Migrating to $HATS_DIR..."
    echo ""

    # Discover existing accounts from v0.2.x credential files
    local found_accounts=()
    for f in "$claude_dir"/.credentials.*.json; do
      [ -f "$f" ] || continue
      local n="${f##*/.credentials.}"
      n="${n%.json}"
      found_accounts+=("$n")
      echo "  Found account: $n"
    done

    # Move everything to base (except per-account files)
    mkdir -p "$HATS_BASE_DIR"

    for item in "$claude_dir"/* "$claude_dir"/.*; do
      [ -e "$item" ] || [ -L "$item" ] || continue
      local bn
      bn=$(basename "$item")

      # Skip . and ..
      [[ "$bn" == "." || "$bn" == ".." ]] && continue

      # Skip per-account credential files
      [[ "$bn" == .credentials.*.json ]] && continue

      # Skip per-account profile files (v0.2.x artifact, will be discarded)
      [[ "$bn" == .profile.*.json ]] && continue

      # Skip active credentials file (will be discarded)
      [ "$bn" = ".credentials.json" ] && continue

      # Skip lock files
      [ "$bn" = ".credentials.lock" ] && continue

      # Skip stash files
      [[ "$bn" == *.stash ]] && continue

      # Move to base (preserving symlinks)
      mv "$item" "$HATS_BASE_DIR/$bn"
    done

    echo "  Moved shared resources to base/"

    # Create account directories
    local first_account=""
    for name in "${found_accounts[@]}"; do
      local acct_dir
      acct_dir=$(_account_dir "$name")
      mkdir -p "$acct_dir"

      # Move credentials
      mv "$claude_dir/.credentials.${name}.json" "$acct_dir/.credentials.json"
      chmod 600 "$acct_dir/.credentials.json"

      # Create isolated .claude.json
      echo '{}' > "$acct_dir/.claude.json"

      # Symlink everything else to base
      _setup_account_dir "$name"

      [ -z "$first_account" ] && first_account="$name"
      echo "  Created account: $name"
    done

    # Determine default
    local default_name=""
    if [ -f "$HOME/.config/hats/default" ]; then
      default_name=$(cat "$HOME/.config/hats/default" 2>/dev/null | tr -d '[:space:]')
    fi
    [ -z "$default_name" ] && default_name="$first_account"

    # Handle the old ~/.claude.json state file
    if [ -f "$HOME/.claude.json" ] && [ -n "$default_name" ]; then
      cp "$HOME/.claude.json" "$(_account_dir "$default_name")/.claude.json"
      # Don't delete the original yet — only after symlink is in place
    fi

    # Remove the now-empty ~/.claude/ directory
    rm -rf "$claude_dir"

    # Set default and create symlink
    if [ -n "$default_name" ]; then
      _set_default "$default_name"
      echo ""
      echo "  Default account: $default_name"
      echo "  ~/.claude -> ~/.hats/claude/$default_name/"
    fi

    # Clean up old ~/.claude.json (now that ~/.claude symlink exists,
    # Claude Code will use $CLAUDE_CONFIG_DIR/.claude.json instead)
    if [ -f "$HOME/.claude.json" ]; then
      mv "$HOME/.claude.json" "$HOME/.claude.json.bak.hats-v1-migration"
      echo "  Backed up ~/.claude.json to ~/.claude.json.bak.hats-v1-migration"
    fi

    echo ""
    echo "  ${#found_accounts[@]} account(s) migrated."
  else
    echo "  No existing ~/.claude/ directory found."
    echo "  Creating fresh hats structure..."
    mkdir -p "$HATS_BASE_DIR"
    echo ""
    echo "  Run 'hats add <name>' to create your first account."
  fi

  # Write config
  mkdir -p "$HATS_DIR"
  [ -f "$HATS_CONFIG" ] || cat > "$HATS_CONFIG" <<EOF
[hats]
version = "$VERSION"
default = "$(_default_account)"
EOF

  echo ""
  echo "Done. Structure: $HATS_DIR"
  echo "Run 'hats list' to see your accounts."
}

cmd_add() {
  local name="${1:-}"
  [ -z "$name" ] && die "Usage: hats add <name>"

  _validate_name "$name"
  [ -d "$HATS_CLAUDE_DIR" ] || die "hats not initialized. Run 'hats init' first."
  _account_exists "$name" && die "Account '$name' already exists."

  local acct_dir
  acct_dir=$(_account_dir "$name")

  echo "Creating account '$name'..."

  # Set up directory with symlinks to base
  _setup_account_dir "$name"

  # Run claude interactively so the user can /login (works on headless machines)
  echo "Starting Claude Code for authentication..."
  echo "Run /login inside the session to authenticate, then /exit when done."
  echo ""
  CLAUDE_CONFIG_DIR="$acct_dir" claude || true

  # Verify credentials were created
  if [ -f "$acct_dir/.credentials.json" ]; then
    chmod 600 "$acct_dir/.credentials.json"
    echo ""
    echo "Account '$name' added."

    # Set as default if first account
    if [ "$(_accounts | wc -l)" -eq 1 ]; then
      _set_default "$name"
      echo "Set as default account."
    fi

    _show_account_status "$name" "$(_default_account)"
  else
    rm -rf "$acct_dir"
    die "No credentials found after session. Account removed."
  fi
}

cmd_remove() {
  local name="${1:-}"
  [ -z "$name" ] && die "Usage: hats remove <name>"

  _account_exists "$name" || die "Account '$name' not found."

  local default
  default=$(_default_account)

  if [ "$name" = "$default" ]; then
    echo "Warning: '$name' is the default account." >&2
    echo "Set a new default with 'hats default <name>' after removal." >&2
  fi

  rm -rf "$(_account_dir "$name")"
  echo "Account '$name' removed."

  # If was default, clear the symlink
  if [ "$name" = "$default" ]; then
    rm -f "$HOME/.claude"
    local new_default
    new_default=$(_accounts | head -1)
    if [ -n "$new_default" ]; then
      _set_default "$new_default"
      echo "New default: $new_default"
    fi
  fi
}

cmd_list() {
  echo "hats v$VERSION — Claude Code Accounts"
  echo "======================================="
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
    echo "  Run 'hats add <name>' to create one."
  fi

  echo ""
  echo "  $count account(s)"
}

cmd_default() {
  local name="${1:-}"

  if [ -z "$name" ]; then
    echo "Default account: $(_default_account)"
    return
  fi

  _account_exists "$name" || die "Account '$name' not found."
  _set_default "$name"
  echo "Default account set to '$name'."
  echo "~/.claude -> ~/.hats/claude/$name/"
}

cmd_swap() {
  local name="${1:-}"
  [ -z "$name" ] && die "Usage: hats swap <name> [-- claude-args...]"
  shift

  [ "${1:-}" = "--" ] && shift

  _account_exists "$name" || die "Account '$name' not found."

  local acct_dir
  acct_dir=$(_account_dir "$name")

  [ -f "$acct_dir/.credentials.json" ] || die "Account '$name' has no credentials. Run: hats add $name"

  CLAUDE_CONFIG_DIR="$acct_dir" claude "$@"
}

cmd_link() {
  local name="${1:-}" resource="${2:-}"
  [ -z "$name" ] || [ -z "$resource" ] && die "Usage: hats link <account> <resource>"

  _account_exists "$name" || die "Account '$name' not found."
  _link_resource "$name" "$resource"
}

cmd_unlink() {
  local name="${1:-}" resource="${2:-}"
  [ -z "$name" ] || [ -z "$resource" ] && die "Usage: hats unlink <account> <resource>"

  _account_exists "$name" || die "Account '$name' not found."
  _unlink_resource "$name" "$resource"
}

cmd_status() {
  local name="${1:-}"

  if [ -z "$name" ]; then
    # Show status for all accounts
    for acct in $(_accounts); do
      cmd_status "$acct"
      echo ""
    done
    return
  fi

  _account_exists "$name" || die "Account '$name' not found."

  local acct_dir default
  acct_dir=$(_account_dir "$name")
  default=$(_default_account)

  local label="$name"
  [ "$name" = "$default" ] && label="$name (default)"

  echo "Account: $label"
  echo "Directory: $acct_dir/"
  echo ""

  echo "  ISOLATED (account-specific):"
  for f in "${ALWAYS_ISOLATED[@]}"; do
    if [ -f "$acct_dir/$f" ]; then
      echo "    $f"
    else
      echo "    $f  (missing)"
    fi
  done

  # Find non-isolated files that are NOT symlinks to base
  local has_diverged=false
  for item in "$acct_dir"/* "$acct_dir"/.*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    local bn
    bn=$(basename "$item")
    [[ "$bn" == "." || "$bn" == ".." ]] && continue
    _is_isolated "$bn" && continue

    if [ ! -L "$item" ]; then
      if [ "$has_diverged" = false ]; then
        echo ""
        echo "  DIVERGED (account-specific, was unlinked):"
        has_diverged=true
      fi
      echo "    $bn"
    fi
  done

  echo ""
  echo "  LINKED (shared with base):"
  for item in "$acct_dir"/* "$acct_dir"/.*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    local bn
    bn=$(basename "$item")
    [[ "$bn" == "." || "$bn" == ".." ]] && continue
    _is_isolated "$bn" && continue

    if [ -L "$item" ]; then
      local target
      target=$(readlink "$item")

      # If the base resource is itself a symlink, show the chain
      local base_item="$HATS_BASE_DIR/$bn"
      if [ -L "$base_item" ]; then
        local final_target
        final_target=$(readlink "$base_item")
        echo "    $bn  ->  base/$bn  ->  $final_target"
      else
        echo "    $bn  ->  base/$bn"
      fi
    fi
  done
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
    local acct_dir
    acct_dir=$(_account_dir "$name")
    echo "${name}() { CLAUDE_CONFIG_DIR=\"$acct_dir\" claude${extra_args} \"\$@\"; }"
  done
}

cmd_fix() {
  echo "Repairing hats state..."

  [ -d "$HATS_DIR" ] || die "hats not initialized. Run 'hats init' first."
  [ -d "$HATS_BASE_DIR" ] || die "Base directory missing at $HATS_BASE_DIR"

  local issues=0

  for name in $(_accounts); do
    local acct_dir
    acct_dir=$(_account_dir "$name")

    # Check credentials
    if [ ! -f "$acct_dir/.credentials.json" ]; then
      echo "  $name: MISSING credentials"
      issues=$((issues + 1))
    fi

    # Check and repair broken symlinks
    for item in "$acct_dir"/* "$acct_dir"/.*; do
      [ -L "$item" ] || continue
      local bn
      bn=$(basename "$item")
      [[ "$bn" == "." || "$bn" == ".." ]] && continue

      if [ ! -e "$item" ]; then
        # Broken symlink
        local expected_target="../base/$bn"
        if [ -e "$HATS_BASE_DIR/$bn" ] || [ -L "$HATS_BASE_DIR/$bn" ]; then
          rm "$item"
          ln -s "$expected_target" "$item"
          echo "  $name: repaired broken symlink $bn"
        else
          rm "$item"
          echo "  $name: removed broken symlink $bn (not in base)"
          issues=$((issues + 1))
        fi
      fi
    done

    # Check for resources in base that are missing from account
    for base_item in "$HATS_BASE_DIR"/* "$HATS_BASE_DIR"/.*; do
      [ -e "$base_item" ] || [ -L "$base_item" ] || continue
      local bn
      bn=$(basename "$base_item")
      [[ "$bn" == "." || "$bn" == ".." ]] && continue
      _is_isolated "$bn" && continue

      if [ ! -e "$acct_dir/$bn" ] && [ ! -L "$acct_dir/$bn" ]; then
        ln -s "../base/$bn" "$acct_dir/$bn"
        echo "  $name: added missing symlink $bn"
      fi
    done
  done

  # Verify ~/.claude symlink
  local default
  default=$(_default_account)
  if [ -n "$default" ]; then
    local expected_target="$HATS_CLAUDE_DIR/$default"
    if [ -L "$HOME/.claude" ]; then
      local current_target
      current_target=$(readlink -f "$HOME/.claude")
      local expected_resolved
      expected_resolved=$(readlink -f "$expected_target")
      if [ "$current_target" != "$expected_resolved" ]; then
        ln -sfn "$expected_target" "$HOME/.claude"
        echo "  Fixed ~/.claude symlink -> $expected_target"
      fi
    elif [ ! -e "$HOME/.claude" ]; then
      ln -sfn "$expected_target" "$HOME/.claude"
      echo "  Created ~/.claude symlink -> $expected_target"
    else
      echo "  WARNING: ~/.claude exists but is not a symlink"
      issues=$((issues + 1))
    fi
  fi

  if [ "$issues" -eq 0 ]; then
    echo "  All good."
  else
    echo "  $issues issue(s) found."
  fi

  echo "Done."
}

cmd_version() {
  echo "hats $VERSION"
}

# ── Main ─────────────────────────────────────────────────────────

case "${1:-}" in
  init)             cmd_init ;;
  add)              cmd_add "${2:-}" ;;
  remove|rm)        cmd_remove "${2:-}" ;;
  list|ls)          cmd_list ;;
  swap)             shift; cmd_swap "$@" ;;
  default)          cmd_default "${2:-}" ;;
  link)             cmd_link "${2:-}" "${3:-}" ;;
  unlink)           cmd_unlink "${2:-}" "${3:-}" ;;
  status)           cmd_status "${2:-}" ;;
  shell-init)       shift; cmd_shell_init "$@" ;;
  fix)              cmd_fix ;;
  version|-v|--version) cmd_version ;;
  help|-h|--help|"")
    cat <<EOF
hats $VERSION — Switch between Claude Code accounts

Usage: hats <command> [args]

Account Management:
  init                 Initialize hats (migrate from ~/.claude/ if exists)
  add <name>           Create a new account and authenticate
  remove <name>        Remove an account
  default [name]       Get or set the default account
  list                 Show all accounts and auth status

Session Management:
  swap <name> [args]   Run claude with account's config directory

Resource Management:
  link <acct> <file>   Share a resource with base (symlink to base)
  unlink <acct> <file> Isolate a resource (copy from base, break symlink)
  status [account]     Show which resources are linked vs isolated

Shell Integration:
  shell-init           Output shell functions for .zshrc/.bashrc
                       Use: eval "\$(hats shell-init)"
                       Flags: --skip-permissions

Maintenance:
  fix                  Repair symlinks, verify auth, detect issues
  version              Show version

Directory Structure:
  ~/.hats/claude/base/     Template (shared resources)
  ~/.hats/claude/<name>/   Per-account config directory
  ~/.claude                Symlink to default account

Environment Variables:
  HATS_DIR             Hats root directory (default: ~/.hats)

Config: $HATS_CONFIG
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
