#!/usr/bin/env bash
# hats — Switch between Claude Code and Codex accounts like changing hats
# https://github.com/CommanderCrowCode/hats

VERSION="1.1.0"
COMMIT="dev"
set -euo pipefail

# Guard: force bash to read the entire script into memory before executing,
# so a mid-session install/upgrade can't corrupt a running instance.
# shellcheck disable=SC2317
{

HATS_DIR="${HATS_DIR:-$HOME/.hats}"
HATS_CONFIG="$HATS_DIR/config.toml"

CURRENT_PROVIDER="claude"
PROVIDER_TITLE=""
PROVIDER_DIR=""
BASE_DIR=""
RUNTIME_DIR=""
RUNTIME_COMMAND=""
RUNTIME_ENV_VAR=""
DEFAULT_KEY=""
PRIMARY_AUTH_FILE=""
ISOLATED_PATTERNS=()
SHARED_ALLOWLIST=()

# ── Helpers ──────────────────────────────────────────────────────

die() { echo "Error: $*" >&2; exit 1; }

_is_supported_provider() {
  case "$1" in
    claude|codex) return 0 ;;
    *) return 1 ;;
  esac
}

_hats_cmd_prefix() {
  if [ "$CURRENT_PROVIDER" = "claude" ]; then
    echo "hats"
  else
    echo "hats $CURRENT_PROVIDER"
  fi
}

_configure_provider() {
  local provider="${1:-claude}"
  _is_supported_provider "$provider" || die "Unsupported provider '$provider'. Supported: claude, codex"

  CURRENT_PROVIDER="$provider"
  PROVIDER_DIR="$HATS_DIR/$CURRENT_PROVIDER"
  BASE_DIR="$PROVIDER_DIR/base"

  case "$CURRENT_PROVIDER" in
    claude)
      PROVIDER_TITLE="Claude Code"
      RUNTIME_DIR="$HOME/.claude"
      RUNTIME_COMMAND="claude"
      RUNTIME_ENV_VAR="CLAUDE_CONFIG_DIR"
      DEFAULT_KEY="default_claude"
      PRIMARY_AUTH_FILE=".credentials.json"
      ISOLATED_PATTERNS=(".credentials.json" ".claude.json")
      SHARED_ALLOWLIST=()
      ;;
    codex)
      PROVIDER_TITLE="Codex"
      RUNTIME_DIR="$HOME/.codex"
      RUNTIME_COMMAND="codex"
      RUNTIME_ENV_VAR="CODEX_HOME"
      DEFAULT_KEY="default_codex"
      PRIMARY_AUTH_FILE="auth.json"
      ISOLATED_PATTERNS=(
        "auth.json"
        "history.jsonl"
        "memories"
        "cache"
        "sessions"
        "shell_snapshots"
        "log"
        ".tmp"
        "tmp"
        "models_cache.json"
        "state_*.sqlite*"
        "logs_*.sqlite*"
      )
      SHARED_ALLOWLIST=(
        "config.toml"
        "plugins"
        "prompts"
        "rules"
        "skills"
        "version.json"
        ".personality_migration"
      )
      ;;
  esac
}

_config_get() {
  local key="$1"
  if [ -f "$HATS_CONFIG" ]; then
    grep -A20 '^\[hats\]' "$HATS_CONFIG" 2>/dev/null | grep "^$key" | head -1 | sed 's/.*=\s*"\?\([^"]*\)"\?/\1/' | tr -d '[:space:]' || true
  fi
}

_ensure_config() {
  mkdir -p "$HATS_DIR"
  if [ ! -f "$HATS_CONFIG" ]; then
    cat > "$HATS_CONFIG" <<EOF
[hats]
version = "$VERSION"
default_provider = "claude"
EOF
  fi
}

_config_set() {
  local key="$1" value="$2"
  _ensure_config

  if grep -q "^$key" "$HATS_CONFIG" 2>/dev/null; then
    sed -i "s#^$key.*#$key = \"$value\"#" "$HATS_CONFIG"
  else
    sed -i "/^\[hats\]/a $key = \"$value\"" "$HATS_CONFIG"
  fi
}

_migrate_legacy_default() {
  # v0.x used a bare `default = "..."` key for the Claude account; v1.1 switched
  # to provider-scoped `default_claude` / `default_codex`. On upgraded configs the
  # legacy key is dead state — read it once, promote to `default_claude` when no
  # provider-specific default is set, then drop the legacy line.
  [ -f "$HATS_CONFIG" ] || return 0

  # Match `^default` followed by whitespace or `=`, NOT `default_claude` / `default_codex` / `default_provider`.
  grep -qE '^default[[:space:]]*=' "$HATS_CONFIG" 2>/dev/null || return 0

  local legacy
  legacy=$(grep -E '^default[[:space:]]*=' "$HATS_CONFIG" | head -1 | sed 's/.*=\s*"\?\([^"]*\)"\?/\1/' | tr -d '[:space:]')
  if [ -n "$legacy" ]; then
    local cur_claude
    cur_claude=$(_config_get "default_claude")
    [ -z "$cur_claude" ] && _config_set "default_claude" "$legacy"
  fi

  sed -i '/^default[[:space:]]*=/d' "$HATS_CONFIG"
}

_default_provider() {
  local val
  val=$(_config_get "default_provider")
  [ -n "$val" ] && echo "$val" || echo "claude"
}

_matches_any_pattern() {
  local value="$1"
  shift || true
  local pattern
  for pattern in "$@"; do
    [[ "$value" == $pattern ]] && return 0
  done
  return 1
}

_is_isolated() {
  _matches_any_pattern "$1" "${ISOLATED_PATTERNS[@]}"
}

_is_shared_by_default() {
  local resource="$1"

  if [ "$CURRENT_PROVIDER" = "claude" ]; then
    _is_isolated "$resource" && return 1
    return 0
  fi

  _matches_any_pattern "$resource" "${SHARED_ALLOWLIST[@]}"
}

_validate_name() {
  local name="$1"
  [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die "Invalid account name '$name'. Use alphanumeric, dots, hyphens, underscores."
  [ "$name" = "base" ] && die "'base' is reserved for the template directory."
  return 0
}

_accounts() {
  [ -d "$PROVIDER_DIR" ] || return 0
  for d in "$PROVIDER_DIR"/*/; do
    [ -d "$d" ] || continue
    local name
    name=$(basename "$d")
    [ "$name" = "base" ] && continue
    echo "$name"
  done | sort
}

_account_dir() { echo "$PROVIDER_DIR/$1"; }

_account_exists() { [ -d "$(_account_dir "$1")" ]; }

_default_account() {
  local val
  val=$(_config_get "$DEFAULT_KEY")
  [ -n "$val" ] && echo "$val" && return
  _accounts | head -1
}

_sync_runtime_symlink() {
  local name="$1"
  ln -sfn "$PROVIDER_DIR/$name" "$RUNTIME_DIR"
}

_set_default() {
  local name="$1"
  _config_set "version" "$VERSION"
  _config_set "default_provider" "$CURRENT_PROVIDER"
  _config_set "$DEFAULT_KEY" "$name"
  _sync_runtime_symlink "$name"
}

_ensure_codex_base_config() {
  [ "$CURRENT_PROVIDER" = "codex" ] || return 0

  mkdir -p "$BASE_DIR"
  if [ ! -f "$BASE_DIR/config.toml" ]; then
    cat > "$BASE_DIR/config.toml" <<EOF
# Shared Codex config managed by hats.
cli_auth_credentials_store = "file"
EOF
    return 0
  fi

  if grep -q '^cli_auth_credentials_store' "$BASE_DIR/config.toml" 2>/dev/null; then
    sed -i 's#^cli_auth_credentials_store.*#cli_auth_credentials_store = "file"#' "$BASE_DIR/config.toml"
  else
    printf '\ncli_auth_credentials_store = "file"\n' >> "$BASE_DIR/config.toml"
  fi
}

_ensure_provider_defaults() {
  [ "$CURRENT_PROVIDER" = "codex" ] && _ensure_codex_base_config
}

_ensure_account_defaults() {
  local acct_dir="$1"
  case "$CURRENT_PROVIDER" in
    claude)
      [ -f "$acct_dir/.claude.json" ] || echo '{}' > "$acct_dir/.claude.json"
      ;;
  esac
}

_provider_login_hint() {
  local auth_mode="${1:-}"
  case "$CURRENT_PROVIDER" in
    claude) echo "Run /login inside the session to authenticate, then /exit when done." ;;
    codex)
      case "$auth_mode" in
        api-key) echo "Codex login will read OPENAI_API_KEY and store file-backed credentials in the account directory." ;;
        device-auth) echo "Codex device auth will run with file-backed credentials stored in the account directory." ;;
        chatgpt|"") echo "Codex ChatGPT login will run with file-backed credentials stored in the account directory." ;;
        *) echo "Codex login will run with file-backed credentials stored in the account directory." ;;
      esac
      ;;
  esac
}

_provider_add_failure_hint() {
  case "$CURRENT_PROVIDER" in
    claude) echo "Run: hats add $1" ;;
    codex) echo "Run: hats codex add $1" ;;
  esac
}

_credential_file() {
  echo "$(_account_dir "$1")/$PRIMARY_AUTH_FILE"
}

_setup_account_dir() {
  local name="$1"
  local acct_dir
  acct_dir=$(_account_dir "$name")

  mkdir -p "$acct_dir"
  _ensure_provider_defaults

  for item in "$BASE_DIR"/* "$BASE_DIR"/.*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    local basename
    basename=$(basename "$item")

    [[ "$basename" == "." || "$basename" == ".." ]] && continue
    _is_isolated "$basename" && continue
    _is_shared_by_default "$basename" || continue

    if [ -e "$acct_dir/$basename" ] || [ -L "$acct_dir/$basename" ]; then
      continue
    fi

    ln -s "../base/$basename" "$acct_dir/$basename"
  done

  _ensure_account_defaults "$acct_dir"
}

_link_resource() {
  local name="$1" resource="$2"
  local acct_dir
  acct_dir=$(_account_dir "$name")

  _is_isolated "$resource" && die "'$resource' is always isolated and cannot be linked."
  [ -e "$BASE_DIR/$resource" ] || [ -L "$BASE_DIR/$resource" ] || die "Resource '$resource' not found in base."

  if [ -L "$acct_dir/$resource" ]; then
    local target
    target=$(readlink "$acct_dir/$resource")
    [[ "$target" == *"base/$resource"* ]] && die "'$resource' is already linked to base."
  fi

  rm -rf "$acct_dir/$resource"
  ln -s "../base/$resource" "$acct_dir/$resource"
  echo "Linked $CURRENT_PROVIDER/$name/$resource -> base/$resource"
}

_unlink_resource() {
  local name="$1" resource="$2"
  local acct_dir
  acct_dir=$(_account_dir "$name")

  _is_isolated "$resource" && die "'$resource' is always isolated."
  [ -L "$acct_dir/$resource" ] || die "'$resource' is already isolated for '$name'."

  local real_path
  real_path=$(realpath "$acct_dir/$resource")

  rm "$acct_dir/$resource"
  cp -a "$real_path" "$acct_dir/$resource"
  echo "Unlinked $CURRENT_PROVIDER/$name/$resource (now isolated)"
}

_token_info_claude() {
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

_token_info_codex() {
  local file="$1"
  local acct_dir
  acct_dir=$(dirname "$file")
  local store="unknown"
  if [ -f "$acct_dir/config.toml" ]; then
    store=$(grep '^cli_auth_credentials_store' "$acct_dir/config.toml" 2>/dev/null | head -1 | sed 's/.*=\s*"\?\([^"]*\)"\?/\1/' | tr -d '[:space:]')
  fi
  [ -n "$store" ] || store="unset"

  python3 -c "
import json, sys
try:
    d = json.load(open('$file'))
    tokens = d.get('tokens') or {}
    print('present=True')
    print(f\"account_id={tokens.get('account_id', 'unknown')}\")
except Exception as e:
    print(f'error={e}')
" 2>/dev/null
  echo "store=$store"
}

_token_info() {
  case "$CURRENT_PROVIDER" in
    claude) _token_info_claude "$1" ;;
    codex) _token_info_codex "$1" ;;
  esac
}

_show_account_status() {
  local name="$1"
  local default="${2:-}"
  local cfile
  cfile=$(_credential_file "$name")

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

  case "$CURRENT_PROVIDER" in
    claude)
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
      ;;
    codex)
      local store account_id
      store=$(echo "$info" | grep -oP 'store=\K.*')
      account_id=$(echo "$info" | grep -oP 'account_id=\K.*')
      if [ "$store" = "file" ]; then
        echo "ok (auth.json present; store=file; account $account_id)"
      else
        echo "ok (auth.json present; store=$store, expected file; account $account_id)"
      fi
      ;;
  esac
}

_normalize_codex_auth_mode() {
  local mode="${1:-}"
  case "$mode" in
    chatgpt|browser|oauth) echo "chatgpt" ;;
    api-key|apikey|key) echo "api-key" ;;
    device|device-auth) echo "device-auth" ;;
    "") echo "" ;;
    *) return 1 ;;
  esac
}

_choose_codex_auth_mode() {
  local requested="${1:-}"
  local normalized=""

  if [ -n "$requested" ]; then
    normalized=$(_normalize_codex_auth_mode "$requested") || die "Unsupported Codex auth mode '$requested'. Use chatgpt, api-key, or device-auth."
    echo "$normalized"
    return 0
  fi

  if [ ! -t 0 ] || [ ! -t 1 ]; then
    if [ -n "${OPENAI_API_KEY:-}" ]; then
      echo "api-key"
      return 0
    fi
    die "Non-interactive Codex account creation requires --api-key with OPENAI_API_KEY set, or --device-auth."
  fi

  echo "Choose Codex authentication for this account:" >&2
  echo "  1) ChatGPT login (opens browser on this machine)" >&2
  echo "  2) API key (reads OPENAI_API_KEY; suitable for headless/CI)" >&2
  echo "  3) Device auth (headless-friendly ChatGPT/device flow)" >&2

  while true; do
    printf "Selection [1]: " >&2
    IFS= read -r choice
    case "${choice:-1}" in
      1) echo "chatgpt"; return 0 ;;
      2)
        [ -n "${OPENAI_API_KEY:-}" ] || die "OPENAI_API_KEY is required for --api-key."
        echo "api-key"
        return 0
        ;;
      3) echo "device-auth"; return 0 ;;
      *) echo "Invalid selection. Enter 1, 2, or 3." >&2 ;;
    esac
  done
}

_run_provider_login() {
  local acct_dir="$1"
  local auth_mode="${2:-}"
  case "$CURRENT_PROVIDER" in
    claude)
      CLAUDE_CONFIG_DIR="$acct_dir" claude || true
      ;;
    codex)
      case "$auth_mode" in
        api-key)
          [ -n "${OPENAI_API_KEY:-}" ] || die "OPENAI_API_KEY is required for Codex API key login."
          printf '%s\n' "$OPENAI_API_KEY" | CODEX_HOME="$acct_dir" codex -c 'cli_auth_credentials_store="file"' login --with-api-key || true
          ;;
        device-auth)
          CODEX_HOME="$acct_dir" codex -c 'cli_auth_credentials_store="file"' login --device-auth || true
          ;;
        chatgpt|"")
          CODEX_HOME="$acct_dir" codex -c 'cli_auth_credentials_store="file"' login || true
          ;;
        *)
          die "Unsupported Codex auth mode '$auth_mode'."
          ;;
      esac
      ;;
  esac
}

_run_provider_command() {
  local acct_dir="$1"
  shift
  case "$CURRENT_PROVIDER" in
    claude)
      CLAUDE_CONFIG_DIR="$acct_dir" claude "$@"
      ;;
    codex)
      CODEX_HOME="$acct_dir" codex -c 'cli_auth_credentials_store="file"' "$@"
      ;;
  esac
}

_sync_new_account_defaults() {
  local name="$1"
  if [ "$(_accounts | wc -l)" -eq 1 ]; then
    _set_default "$name"
    echo "Set as default account."
  fi
}

_init_claude_provider() {
  local claude_dir="$RUNTIME_DIR"

  if [ -d "$claude_dir" ]; then
    echo "  Found existing $claude_dir/ directory"
    echo "  Migrating to $PROVIDER_DIR..."
    echo ""

    local found_accounts=()
    for f in "$claude_dir"/.credentials.*.json; do
      [ -f "$f" ] || continue
      local n="${f##*/.credentials.}"
      n="${n%.json}"
      found_accounts+=("$n")
      echo "  Found account: $n"
    done

    mkdir -p "$BASE_DIR"

    for item in "$claude_dir"/* "$claude_dir"/.*; do
      [ -e "$item" ] || [ -L "$item" ] || continue
      local bn
      bn=$(basename "$item")

      [[ "$bn" == "." || "$bn" == ".." ]] && continue
      [[ "$bn" == .credentials.*.json ]] && continue
      [[ "$bn" == .profile.*.json ]] && continue
      [ "$bn" = ".credentials.json" ] && continue
      [ "$bn" = ".credentials.lock" ] && continue
      [[ "$bn" == *.stash ]] && continue

      mv "$item" "$BASE_DIR/$bn"
    done

    echo "  Moved shared resources to base/"

    local first_account=""
    local name
    for name in "${found_accounts[@]}"; do
      local acct_dir
      acct_dir=$(_account_dir "$name")
      mkdir -p "$acct_dir"
      mv "$claude_dir/.credentials.${name}.json" "$acct_dir/.credentials.json"
      chmod 600 "$acct_dir/.credentials.json"
      echo '{}' > "$acct_dir/.claude.json"
      _setup_account_dir "$name"
      [ -z "$first_account" ] && first_account="$name"
      echo "  Created account: $name"
    done

    local default_name=""
    if [ -f "$HOME/.config/hats/default" ]; then
      default_name=$(tr -d '[:space:]' < "$HOME/.config/hats/default" 2>/dev/null)
    fi
    [ -z "$default_name" ] && default_name="$first_account"

    if [ -f "$HOME/.claude.json" ] && [ -n "$default_name" ]; then
      cp "$HOME/.claude.json" "$(_account_dir "$default_name")/.claude.json"
    fi

    rm -rf "$claude_dir"

    if [ -n "$default_name" ]; then
      _set_default "$default_name"
      echo ""
      echo "  Default account: $default_name"
      echo "  $RUNTIME_DIR -> $PROVIDER_DIR/$default_name/"
    fi

    if [ -f "$HOME/.claude.json" ]; then
      mv "$HOME/.claude.json" "$HOME/.claude.json.bak.hats-v1-migration"
      echo "  Backed up ~/.claude.json to ~/.claude.json.bak.hats-v1-migration"
    fi

    echo ""
    echo "  ${#found_accounts[@]} account(s) migrated."
  else
    echo "  No existing $claude_dir/ directory found."
    echo "  Creating fresh hats structure..."
    mkdir -p "$BASE_DIR"
    echo ""
    echo "  Run 'hats add <name>' to create your first account."
  fi
}

_init_codex_provider() {
  local codex_dir="$RUNTIME_DIR"
  mkdir -p "$BASE_DIR"
  _ensure_codex_base_config

  if [ -d "$codex_dir" ]; then
    echo "  Found existing $codex_dir/ directory"
    echo "  Migrating current Codex state into hats account 'default'..."
    echo ""

    local default_name="default"
    local acct_dir
    acct_dir=$(_account_dir "$default_name")
    mkdir -p "$acct_dir"

    for item in "$codex_dir"/* "$codex_dir"/.*; do
      [ -e "$item" ] || [ -L "$item" ] || continue
      local bn
      bn=$(basename "$item")
      [[ "$bn" == "." || "$bn" == ".." ]] && continue

      if _is_shared_by_default "$bn"; then
        mv "$item" "$BASE_DIR/$bn"
      else
        mv "$item" "$acct_dir/$bn"
      fi
    done

    _ensure_codex_base_config
    _setup_account_dir "$default_name"

    if [ -f "$acct_dir/auth.json" ]; then
      chmod 600 "$acct_dir/auth.json"
    fi

    rm -rf "$codex_dir"
    _set_default "$default_name"

    echo "  Created account: $default_name"
    echo "  Default account: $default_name"
    echo "  $RUNTIME_DIR -> $PROVIDER_DIR/$default_name/"
    echo ""
    echo "  1 account(s) migrated."
  else
    echo "  No existing $codex_dir/ directory found."
    echo "  Creating fresh hats structure..."
    mkdir -p "$BASE_DIR"
    _ensure_codex_base_config
    echo ""
    echo "  Run 'hats codex add <name>' to create your first Codex account."
  fi
}

# ── Commands ─────────────────────────────────────────────────────

cmd_init() {
  if [ -d "$PROVIDER_DIR" ] && [ -d "$BASE_DIR" ]; then
    echo "hats is already initialized for $CURRENT_PROVIDER at $PROVIDER_DIR"
    echo ""
    echo "Accounts:"
    for name in $(_accounts); do
      echo "  $name -> $(_account_dir "$name")"
    done
    echo ""
    echo "Default: $(_default_account)"
    return
  fi

  echo "Initializing hats v$VERSION for $PROVIDER_TITLE..."
  echo ""

  if [ -L "$RUNTIME_DIR" ]; then
    die "$RUNTIME_DIR is already a symlink ($(readlink "$RUNTIME_DIR")). Remove it first or check if hats is already set up."
  fi

  mkdir -p "$PROVIDER_DIR"

  case "$CURRENT_PROVIDER" in
    claude) _init_claude_provider ;;
    codex) _init_codex_provider ;;
  esac

  _config_set "version" "$VERSION"

  echo ""
  echo "Done. Structure: $PROVIDER_DIR"
  echo "Run '$(_hats_cmd_prefix) list' to see your accounts."
}

cmd_add() {
  local name="${1:-}"
  [ -z "$name" ] && die "Usage: $(_hats_cmd_prefix) add <name>"

  local auth_mode=""
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --chatgpt)
        auth_mode="chatgpt"
        ;;
      --api-key)
        auth_mode="api-key"
        ;;
      --device-auth)
        auth_mode="device-auth"
        ;;
      --auth)
        shift || die "Usage: $(_hats_cmd_prefix) add <name> [--chatgpt|--api-key|--device-auth|--auth <mode>]"
        [ $# -gt 0 ] || die "Usage: $(_hats_cmd_prefix) add <name> [--chatgpt|--api-key|--device-auth|--auth <mode>]"
        auth_mode="$1"
        ;;
      --auth=*)
        auth_mode="${1#--auth=}"
        ;;
      *)
        die "Usage: $(_hats_cmd_prefix) add <name> [--chatgpt|--api-key|--device-auth|--auth <mode>]"
        ;;
    esac
    shift || true
  done

  if [ "$CURRENT_PROVIDER" = "codex" ]; then
    auth_mode=$(_choose_codex_auth_mode "$auth_mode")
  elif [ -n "$auth_mode" ]; then
    die "Auth mode flags are only supported for hats codex add."
  fi

  _validate_name "$name"
  [ -d "$PROVIDER_DIR" ] || die "hats not initialized for $CURRENT_PROVIDER. Run '$(_hats_cmd_prefix) init'."
  _account_exists "$name" && die "Account '$name' already exists."

  local acct_dir
  acct_dir=$(_account_dir "$name")

  echo "Creating $CURRENT_PROVIDER account '$name'..."

  _setup_account_dir "$name"

  echo "Starting $PROVIDER_TITLE for authentication..."
  echo "$(_provider_login_hint "$auth_mode")"
  echo ""
  _run_provider_login "$acct_dir" "$auth_mode"

  if [ -f "$(_credential_file "$name")" ]; then
    chmod 600 "$(_credential_file "$name")" 2>/dev/null || true
    echo ""
    echo "Account '$name' added."
    _sync_new_account_defaults "$name"
    _show_account_status "$name" "$(_default_account)"
  else
    rm -rf "$acct_dir"
    die "No credentials found after session. Account removed."
  fi
}

cmd_remove() {
  local name="${1:-}"
  [ -z "$name" ] && die "Usage: $(_hats_cmd_prefix) remove <name>"

  _account_exists "$name" || die "Account '$name' not found."

  local default
  default=$(_default_account)

  if [ "$name" = "$default" ]; then
    echo "Warning: '$name' is the default account." >&2
    echo "Set a new default with '$(_hats_cmd_prefix) default <name>' after removal." >&2
  fi

  rm -rf "$(_account_dir "$name")"
  echo "Account '$name' removed."

  if [ "$name" = "$default" ]; then
    rm -f "$RUNTIME_DIR"
    local new_default
    new_default=$(_accounts | head -1)
    if [ -n "$new_default" ]; then
      _set_default "$new_default"
      echo "New default: $new_default"
    fi
  fi
}

cmd_rename() {
  local old_name="${1:-}" new_name="${2:-}"
  [ -z "$old_name" ] || [ -z "$new_name" ] && die "Usage: $(_hats_cmd_prefix) rename <old-name> <new-name>"

  _account_exists "$old_name" || die "Account '$old_name' not found."
  _validate_name "$new_name"
  _account_exists "$new_name" && die "Account '$new_name' already exists."
  [ "$old_name" = "$new_name" ] && die "Old and new account names must differ."

  mv "$(_account_dir "$old_name")" "$(_account_dir "$new_name")"
  echo "Account '$old_name' renamed to '$new_name'."

  if [ "$old_name" = "$(_default_account)" ]; then
    _set_default "$new_name"
    echo "Default account set to '$new_name'."
    echo "$RUNTIME_DIR -> $PROVIDER_DIR/$new_name/"
  fi
}

cmd_list() {
  echo "hats v$VERSION — $PROVIDER_TITLE Accounts"
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
    echo "  Run '$(_hats_cmd_prefix) add <name>' to create one."
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
  echo "$RUNTIME_DIR -> $PROVIDER_DIR/$name/"
}

cmd_swap() {
  local name="${1:-}"
  [ -z "$name" ] && die "Usage: $(_hats_cmd_prefix) swap <name> [-- args...]"
  shift

  [ "${1:-}" = "--" ] && shift

  _account_exists "$name" || die "Account '$name' not found."

  local acct_dir
  acct_dir=$(_account_dir "$name")

  [ -f "$(_credential_file "$name")" ] || die "Account '$name' has no credentials. $(_provider_add_failure_hint "$name")"
  _run_provider_command "$acct_dir" "$@"
}

cmd_link() {
  local name="${1:-}" resource="${2:-}"
  [ -z "$name" ] || [ -z "$resource" ] && die "Usage: $(_hats_cmd_prefix) link <account> <resource>"

  _account_exists "$name" || die "Account '$name' not found."
  _link_resource "$name" "$resource"
}

cmd_unlink() {
  local name="${1:-}" resource="${2:-}"
  [ -z "$name" ] || [ -z "$resource" ] && die "Usage: $(_hats_cmd_prefix) unlink <account> <resource>"

  _account_exists "$name" || die "Account '$name' not found."
  _unlink_resource "$name" "$resource"
}

cmd_status() {
  local name="${1:-}"

  if [ -z "$name" ]; then
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

  echo "Provider: $CURRENT_PROVIDER"
  echo "Account: $label"
  echo "Directory: $acct_dir/"
  echo ""

  echo "  ISOLATED (account-specific):"
  local shown=false
  local item
  for item in "$acct_dir"/* "$acct_dir"/.*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    local bn
    bn=$(basename "$item")
    [[ "$bn" == "." || "$bn" == ".." ]] && continue
    if _is_isolated "$bn"; then
      echo "    $bn"
      shown=true
    fi
  done
  [ "$shown" = false ] && echo "    (none)"

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
  local linked_any=false
  for item in "$acct_dir"/* "$acct_dir"/.*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    local bn
    bn=$(basename "$item")
    [[ "$bn" == "." || "$bn" == ".." ]] && continue
    _is_isolated "$bn" && continue

    if [ -L "$item" ]; then
      linked_any=true
      local base_item="$BASE_DIR/$bn"
      if [ -L "$base_item" ]; then
        local final_target
        final_target=$(readlink "$base_item")
        echo "    $bn  ->  base/$bn  ->  $final_target"
      else
        echo "    $bn  ->  base/$bn"
      fi
    fi
  done
  [ "$linked_any" = false ] && echo "    (none)"
}

cmd_shell_init() {
  local extra_args=""
  local arg
  for arg in "$@"; do
    case "$arg" in
      --skip-permissions)
        if [ "$CURRENT_PROVIDER" = "claude" ]; then
          extra_args=" --dangerously-skip-permissions"
        else
          die "--skip-permissions is only supported for Claude Code shell shims."
        fi
        ;;
    esac
  done

  cat <<HEADER
# Generated by hats shell-init for $CURRENT_PROVIDER
# Add to your shell config:
#   eval "\$($(_hats_cmd_prefix) shell-init)"
HEADER

  if [ "$CURRENT_PROVIDER" = "claude" ]; then
    echo "#   eval \"\$(hats shell-init)\""
    echo "#   eval \"\$(hats shell-init --skip-permissions)\"  # to auto-skip permission prompts"
  fi
  echo ""

  for name in $(_accounts); do
    local acct_dir
    acct_dir=$(_account_dir "$name")
    local fn_name="$name"
    [ "$CURRENT_PROVIDER" = "codex" ] && fn_name="codex_$name"
    if [ "$CURRENT_PROVIDER" = "codex" ]; then
      echo "${fn_name}() { $RUNTIME_ENV_VAR=\"$acct_dir\" $RUNTIME_COMMAND -c 'cli_auth_credentials_store=\"file\"' \"\$@\"; }"
    else
      echo "${fn_name}() { $RUNTIME_ENV_VAR=\"$acct_dir\" $RUNTIME_COMMAND${extra_args} \"\$@\"; }"
    fi
  done
}

cmd_fix() {
  echo "Repairing hats state for $CURRENT_PROVIDER..."

  [ -d "$PROVIDER_DIR" ] || die "hats not initialized for $CURRENT_PROVIDER. Run '$(_hats_cmd_prefix) init'."
  [ -d "$BASE_DIR" ] || die "Base directory missing at $BASE_DIR"

  local issues=0
  _ensure_provider_defaults

  for name in $(_accounts); do
    local acct_dir
    acct_dir=$(_account_dir "$name")

    if [ ! -f "$acct_dir/$PRIMARY_AUTH_FILE" ]; then
      echo "  $name: MISSING credentials"
      issues=$((issues + 1))
    fi

    for item in "$acct_dir"/* "$acct_dir"/.*; do
      [ -L "$item" ] || continue
      local bn
      bn=$(basename "$item")
      [[ "$bn" == "." || "$bn" == ".." ]] && continue

      if [ ! -e "$item" ]; then
        local expected_target="../base/$bn"
        if [ -e "$BASE_DIR/$bn" ] || [ -L "$BASE_DIR/$bn" ]; then
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

    for base_item in "$BASE_DIR"/* "$BASE_DIR"/.*; do
      [ -e "$base_item" ] || [ -L "$base_item" ] || continue
      local bn
      bn=$(basename "$base_item")
      [[ "$bn" == "." || "$bn" == ".." ]] && continue
      _is_isolated "$bn" && continue
      _is_shared_by_default "$bn" || continue

      if [ ! -e "$acct_dir/$bn" ] && [ ! -L "$acct_dir/$bn" ]; then
        ln -s "../base/$bn" "$acct_dir/$bn"
        echo "  $name: added missing symlink $bn"
      fi
    done

    _ensure_account_defaults "$acct_dir"
  done

  local default
  default=$(_default_account)
  if [ -n "$default" ]; then
    local expected_target="$PROVIDER_DIR/$default"
    if [ -L "$RUNTIME_DIR" ]; then
      local current_target
      current_target=$(readlink -f "$RUNTIME_DIR")
      local expected_resolved
      expected_resolved=$(readlink -f "$expected_target")
      if [ "$current_target" != "$expected_resolved" ]; then
        ln -sfn "$expected_target" "$RUNTIME_DIR"
        echo "  Fixed $RUNTIME_DIR symlink -> $expected_target"
      fi
    elif [ ! -e "$RUNTIME_DIR" ]; then
      ln -sfn "$expected_target" "$RUNTIME_DIR"
      echo "  Created $RUNTIME_DIR symlink -> $expected_target"
    else
      echo "  WARNING: $RUNTIME_DIR exists but is not a symlink"
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

cmd_doctor() {
  echo "Running hats doctor for $CURRENT_PROVIDER..."

  local issues=0
  local warnings=0

  # 1. Tooling — python3 used by list for token inspection; provider CLI must exist.
  if command -v python3 >/dev/null 2>&1; then
    echo "  OK   python3 found ($(python3 --version 2>&1))"
  else
    echo "  FAIL python3 not on PATH"
    issues=$((issues + 1))
  fi

  if command -v "$RUNTIME_COMMAND" >/dev/null 2>&1; then
    echo "  OK   $RUNTIME_COMMAND found"
  else
    echo "  FAIL $RUNTIME_COMMAND not on PATH"
    issues=$((issues + 1))
  fi

  # 2. Layout — provider + base dirs.
  if [ -d "$PROVIDER_DIR" ]; then
    echo "  OK   provider dir $PROVIDER_DIR"
  else
    echo "  FAIL provider dir missing: $PROVIDER_DIR (run '$(_hats_cmd_prefix) init')"
    issues=$((issues + 1))
    echo "Done. $issues issue(s), $warnings warning(s)."
    return 1
  fi

  if [ -d "$BASE_DIR" ]; then
    echo "  OK   base dir $BASE_DIR"
  else
    echo "  FAIL base dir missing: $BASE_DIR"
    issues=$((issues + 1))
  fi

  # 3. Default-account runtime symlink (~/.claude or ~/.codex).
  local default
  default=$(_default_account)
  if [ -z "$default" ]; then
    echo "  WARN no default account configured (bare '$RUNTIME_COMMAND' won't resolve)"
    warnings=$((warnings + 1))
  elif [ -L "$RUNTIME_DIR" ]; then
    local current_target expected_resolved
    current_target=$(readlink -f "$RUNTIME_DIR" 2>/dev/null || true)
    expected_resolved=$(readlink -f "$PROVIDER_DIR/$default" 2>/dev/null || true)
    if [ -n "$current_target" ] && [ "$current_target" = "$expected_resolved" ]; then
      echo "  OK   $RUNTIME_DIR -> default account '$default'"
    else
      echo "  FAIL $RUNTIME_DIR -> $current_target (expected $expected_resolved). Run '$(_hats_cmd_prefix) fix'."
      issues=$((issues + 1))
    fi
  elif [ -e "$RUNTIME_DIR" ]; then
    echo "  FAIL $RUNTIME_DIR exists but is not a symlink"
    issues=$((issues + 1))
  else
    echo "  WARN $RUNTIME_DIR missing (bare '$RUNTIME_COMMAND' won't resolve)"
    warnings=$((warnings + 1))
  fi

  # 4. Per-account checks.
  for name in $(_accounts); do
    local acct_dir
    acct_dir=$(_account_dir "$name")
    echo "  [$name]"

    # 4a. Primary auth file presence + permissions.
    local auth_file="$acct_dir/$PRIMARY_AUTH_FILE"
    if [ ! -f "$auth_file" ]; then
      echo "    FAIL $PRIMARY_AUTH_FILE missing (run '$(_hats_cmd_prefix) add $name' or '/login')"
      issues=$((issues + 1))
    else
      local mode
      mode=$(stat -c '%a' "$auth_file" 2>/dev/null || stat -f '%Lp' "$auth_file" 2>/dev/null || echo "?")
      case "$mode" in
        600|400)
          echo "    OK   $PRIMARY_AUTH_FILE mode=$mode"
          ;;
        ?)
          echo "    WARN $PRIMARY_AUTH_FILE mode unknown (stat failed)"
          warnings=$((warnings + 1))
          ;;
        *)
          echo "    WARN $PRIMARY_AUTH_FILE mode=$mode (expected 600 or 400 — credentials should not be group/other readable)"
          warnings=$((warnings + 1))
          ;;
      esac
    fi

    # 4b. Broken symlinks.
    local broken=0
    for item in "$acct_dir"/* "$acct_dir"/.*; do
      [ -L "$item" ] || continue
      local bn
      bn=$(basename "$item")
      [[ "$bn" == "." || "$bn" == ".." ]] && continue
      if [ ! -e "$item" ]; then
        echo "    FAIL broken symlink: $bn"
        broken=$((broken + 1))
        issues=$((issues + 1))
      fi
    done
    [ "$broken" -eq 0 ] && echo "    OK   no broken symlinks"

    # 4c. Missing expected shared resources.
    local missing=0
    for base_item in "$BASE_DIR"/* "$BASE_DIR"/.*; do
      [ -e "$base_item" ] || [ -L "$base_item" ] || continue
      local bn
      bn=$(basename "$base_item")
      [[ "$bn" == "." || "$bn" == ".." ]] && continue
      _is_isolated "$bn" && continue
      _is_shared_by_default "$bn" || continue
      if [ ! -e "$acct_dir/$bn" ] && [ ! -L "$acct_dir/$bn" ]; then
        echo "    WARN missing shared resource: $bn (run '$(_hats_cmd_prefix) fix')"
        missing=$((missing + 1))
        warnings=$((warnings + 1))
      fi
    done
    [ "$missing" -eq 0 ] && echo "    OK   all shared resources present"

    # 4d. Locally-modified shared resources — present but NOT a symlink, when
    # a shared-by-default file of the same name exists in base. This catches the
    # shannon/settings.json class of drift.
    local unlinked=0
    for item in "$acct_dir"/* "$acct_dir"/.*; do
      [ -e "$item" ] || continue
      [ -L "$item" ] && continue
      local bn
      bn=$(basename "$item")
      [[ "$bn" == "." || "$bn" == ".." ]] && continue
      _is_isolated "$bn" && continue
      _is_shared_by_default "$bn" || continue
      [ -e "$BASE_DIR/$bn" ] || [ -L "$BASE_DIR/$bn" ] || continue
      echo "    WARN locally-overridden shared resource: $bn (diverges from base)"
      unlinked=$((unlinked + 1))
      warnings=$((warnings + 1))
    done
    [ "$unlinked" -eq 0 ] && echo "    OK   no unintended shared-resource overrides"
  done

  echo "Done. $issues issue(s), $warnings warning(s)."
  [ "$issues" -eq 0 ]
}

cmd_providers() {
  echo "Supported providers:"
  echo "  claude"
  echo "  codex"
  echo ""
  echo "Default provider: $(_default_provider)"
}

cmd_version() {
  echo "hats $VERSION ($COMMIT)"
}

cmd_help() {
  cat <<EOF
hats $VERSION — Switch between Claude Code and Codex accounts

Usage:
  hats <command> [args]              # Claude Code (backward compatible default)
  hats <provider> <command> [args]   # Provider-specific mode

Providers:
  claude
  codex

Account Management:
  init                 Initialize hats for the active provider
  add <name>           Create a new account and authenticate
  remove <name>        Remove an account
  rename <old> <new>   Rename an account
  default [name]       Get or set the default account
  list                 Show all accounts and auth status

Session Management:
  swap <name> [args]   Run the provider CLI with the account's isolated home

Resource Management:
  link <acct> <file>   Share a resource with base (symlink to base)
  unlink <acct> <file> Isolate a resource (copy from base, break symlink)
  status [account]     Show which resources are linked vs isolated

Shell Integration:
  shell-init           Output shell functions for your shell config

Maintenance:
  fix                  Repair symlinks, verify auth, detect issues
  doctor               Read-only health check (tooling, layout, symlinks, permissions)
  providers            Show supported providers
  version              Show version

Examples:
  hats init
  hats add work
  hats rename work personal
  hats swap work -- --model opus
  hats codex init
  hats codex add personal
  hats codex add headless --api-key
  hats codex add remote --device-auth
  hats codex swap personal -- exec "summarize this repo"

Directory Structure:
  ~/.hats/claude/base/     Shared Claude resources
  ~/.hats/claude/<name>/   Per-account Claude config directory
  ~/.hats/codex/base/      Shared Codex resources
  ~/.hats/codex/<name>/    Per-account Codex home directory
  ~/.claude                Symlink to default Claude account
  ~/.codex                 Symlink to default Codex account

Environment Variables:
  HATS_DIR             Hats root directory (default: ~/.hats)

Config: $HATS_CONFIG
EOF
}

# ── Main ─────────────────────────────────────────────────────────

_migrate_legacy_default

provider_candidate="${1:-}"
if _is_supported_provider "$provider_candidate"; then
  _configure_provider "$provider_candidate"
  shift
else
  _configure_provider "claude"
fi

case "${1:-}" in
  init)             cmd_init ;;
  add)              shift; cmd_add "$@" ;;
  remove|rm)        cmd_remove "${2:-}" ;;
  rename|mv)        cmd_rename "${2:-}" "${3:-}" ;;
  list|ls)          cmd_list ;;
  swap)             shift; cmd_swap "$@" ;;
  default)          cmd_default "${2:-}" ;;
  link)             cmd_link "${2:-}" "${3:-}" ;;
  unlink)           cmd_unlink "${2:-}" "${3:-}" ;;
  status)           cmd_status "${2:-}" ;;
  shell-init)       shift; cmd_shell_init "$@" ;;
  fix)              cmd_fix ;;
  doctor)           cmd_doctor ;;
  providers)        cmd_providers ;;
  version|-v|--version) cmd_version ;;
  help|-h|--help|"") cmd_help ;;
  *)
    echo "Unknown command: $1" >&2
    echo "Run 'hats help' for usage." >&2
    exit 1
    ;;
esac
exit
}
