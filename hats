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
# Audit log: opt-in via HATS_AUDIT=1 (default path $HATS_DIR/audit.log) OR
# HATS_AUDIT_LOG=/custom/path. Records account-mutating + swap events as
# one JSON object per line (JSONL). Read-only commands (list/doctor/help/
# version/status/completion/providers) are NOT logged — they don't mutate
# state and would otherwise dwarf the signal on shared machines.
HATS_AUDIT="${HATS_AUDIT:-0}"
HATS_AUDIT_LOG="${HATS_AUDIT_LOG:-$HATS_DIR/audit.log}"

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

# Append one JSON line to the audit log. No-op unless HATS_AUDIT=1. Keys
# are passed as alternating name/value args after the event string. Values
# are shell-escaped by python3 (same argv-via-stdin pattern as _token_info_*
# to avoid shell-meta injection from $USER / account names). Errors are
# swallowed — audit failure must never break the user's command.
_audit_log() {
  [ "$HATS_AUDIT" = "1" ] || return 0
  local event="$1"; shift
  local logdir
  logdir=$(dirname "$HATS_AUDIT_LOG")
  mkdir -p "$logdir" 2>/dev/null || return 0
  python3 - "$HATS_AUDIT_LOG" "$event" "$CURRENT_PROVIDER" "${USER:-unknown}" "$@" <<'PYEOF' 2>/dev/null || true
import datetime, json, os, sys
log_path, event, provider, user = sys.argv[1:5]
kv_args = sys.argv[5:]
entry = {
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "event": event,
    "provider": provider,
    "user": user,
}
# Alternating key/value pairs after the fixed prefix
for i in range(0, len(kv_args) - 1, 2):
    entry[kv_args[i]] = kv_args[i + 1]
line = json.dumps(entry, separators=(",", ":"))
# Append is atomic under POSIX for writes <= PIPE_BUF (4KB); each JSONL
# line stays well under that limit.
with open(log_path, "a", encoding="utf-8") as f:
    f.write(line + "\n")
PYEOF
}

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
    grep -A20 '^\[hats\]' "$HATS_CONFIG" 2>/dev/null | grep "^$key" | head -1 | sed -E 's/^[^=]*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/' | tr -d '[:space:]' || true
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

_sed_i() {
  # Portable sed -i across GNU (Linux) and BSD (macOS) sed.
  # GNU: `sed -i '<expr>' file`; BSD: `sed -i '' '<expr>' file`.
  # Both accept `-i.bak` with an extension — use that + remove the backup.
  local expr="$1" file="$2"
  sed -i.bak "$expr" "$file"
  rm -f "$file.bak"
}

_realpath() {
  # Portable equivalent of GNU `readlink -f`: BSD (macOS) readlink lacks -f.
  # python3 is already a hats dependency.
  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null
}

_should_color() {
  # Color is on when: stdout is a TTY, NO_COLOR env var is unset, and --no-color
  # flag wasn't passed. Honors the NO_COLOR standard (https://no-color.org).
  [ "${HATS_NO_COLOR:-0}" = "0" ] || return 1
  [ -z "${NO_COLOR:-}" ] || return 1
  [ -t 1 ] || return 1
  return 0
}

_colorize_stream() {
  # Read stdin and color the leading OK/WARN/FAIL tokens on each line.
  # Matches only the token at the start of the line (after indent), so prose
  # that happens to contain these words downstream isn't affected.
  if ! _should_color; then
    cat
    return 0
  fi
  local esc
  esc=$'\033'
  sed -E "
    s/^([[:space:]]*)OK([[:space:]])/\\1${esc}[32mOK${esc}[0m\\2/
    s/^([[:space:]]*)WARN([[:space:]])/\\1${esc}[33mWARN${esc}[0m\\2/
    s/^([[:space:]]*)FAIL([[:space:]])/\\1${esc}[31mFAIL${esc}[0m\\2/
  "
}

_config_set() {
  local key="$1" value="$2"
  _ensure_config
  # Python handles read/modify/write with proper string escaping so that
  # `value` can contain sed/awk metacharacters (`#`, `&`, `\`, `\n`) without
  # corrupting the config file. Closes audit finding #2 / issue #5.
  python3 - "$HATS_CONFIG" "$key" "$value" <<'PYEOF'
import sys, re, json, os, tempfile
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    lines = f.readlines()
pat = re.compile(r"^" + re.escape(key) + r"\s*=")
new_line = f"{key} = {json.dumps(val)}\n"
out = []
found = False
for ln in lines:
    if pat.match(ln):
        out.append(new_line)
        found = True
    else:
        out.append(ln)
if not found:
    final = []
    inserted = False
    for ln in out:
        final.append(ln)
        if not inserted and ln.strip() == "[hats]":
            final.append(new_line)
            inserted = True
    out = final
dirn = os.path.dirname(path) or "."
fd, tmp = tempfile.mkstemp(prefix=".hatscfg.", dir=dirn)
try:
    with os.fdopen(fd, "w") as f:
        f.writelines(out)
    os.replace(tmp, path)
except Exception:
    os.unlink(tmp)
    raise
PYEOF
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
  # POSIX-portable sed regex: BSD sed doesn't recognize `\s` or BRE `\?`.
  # Use `[[:space:]]*` and ERE via `-E` for the optional quote.
  legacy=$(grep -E '^default[[:space:]]*=' "$HATS_CONFIG" | head -1 | sed -E 's/^[^=]*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/' | tr -d '[:space:]')
  if [ -n "$legacy" ]; then
    local cur_claude
    cur_claude=$(_config_get "default_claude")
    [ -z "$cur_claude" ] && _config_set "default_claude" "$legacy"
  fi

  _sed_i '/^default[[:space:]]*=/d' "$HATS_CONFIG"
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
    # shellcheck disable=SC2053
    # Intentional glob match: `$pattern` is a glob like `.credentials*.json`,
    # not a literal — unquoted RHS is required for `[[ == ]]` to glob-match.
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
    _sed_i 's#^cli_auth_credentials_store.*#cli_auth_credentials_store = "file"#' "$BASE_DIR/config.toml"
  else
    printf '\ncli_auth_credentials_store = "file"\n' >> "$BASE_DIR/config.toml"
  fi
}

_ensure_provider_defaults() {
  [ "$CURRENT_PROVIDER" = "codex" ] && _ensure_codex_base_config
  # Always return 0. Under `set -euo pipefail` the trailing short-circuited
  # `[ ... ] && ...` returns the test's exit code (1) for provider=claude, and
  # bash errexit would terminate any caller that doesn't wrap the call in a
  # conditional — in particular `cmd_fix`, which was silently aborting after
  # the header line on fresh sandboxes before any base symlinks existed.
  return 0
}

_ensure_account_defaults() {
  local acct_dir="$1"
  case "$CURRENT_PROVIDER" in
    claude)
      [ -f "$acct_dir/.claude.json" ] || echo '{}' > "$acct_dir/.claude.json"
      ;;
    codex)
      # Codex has no per-account default-state file analogous to .claude.json.
      # `_ensure_codex_base_config` already handles base-level defaults. Leave
      # this arm explicit so hats-fleet-symmetry-check doesn't flag the block
      # as a missing-codex-branch.
      :
      ;;
  esac
}

_dedupe_claude_hook_registrations() {
  # Rewrite base/settings.json with duplicate hook entries collapsed to one
  # per (event, matcher, command-set) fingerprint. First occurrence wins;
  # remaining order is preserved. Silent no-op when absent / unreadable /
  # already deduped. Emits one tab-separated line per event+matcher that had
  # removals so the caller can report.
  [ "$CURRENT_PROVIDER" = "claude" ] || return 0
  [ -f "$BASE_DIR/settings.json" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0

  python3 - "$BASE_DIR/settings.json" <<'PY' 2>/dev/null || true
import json, os, sys, tempfile
from collections import Counter

path = sys.argv[1]
try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    sys.exit(0)

hooks = d.get("hooks") or {}
if not isinstance(hooks, dict):
    sys.exit(0)

any_change = False
report_lines = []
for event_name, event_items in hooks.items():
    if not isinstance(event_items, list):
        continue
    fps = []
    for item in event_items:
        if not isinstance(item, dict):
            fps.append(None)
            continue
        matcher = item.get("matcher", "") or ""
        cmds = tuple(sorted(
            (h.get("command") or "") for h in (item.get("hooks") or [])
            if isinstance(h, dict)
        ))
        fps.append((matcher, cmds))
    counts = Counter(fp for fp in fps if fp is not None)
    if not any(n > 1 for n in counts.values()):
        continue
    seen = set()
    unique = []
    for item, fp in zip(event_items, fps):
        if fp is None:
            unique.append(item)
            continue
        if fp in seen:
            continue
        seen.add(fp)
        unique.append(item)
    hooks[event_name] = unique
    any_change = True
    for (matcher, _cmds), n in sorted(counts.items()):
        if n <= 1:
            continue
        disp = matcher if matcher else "(no-matcher)"
        report_lines.append(f"{event_name}\t{disp}\t{n - 1}")

if any_change:
    dirn = os.path.dirname(path) or "."
    tmp = tempfile.NamedTemporaryFile(
        mode="w", delete=False, dir=dirn, prefix=".settings.", suffix=".tmp"
    )
    try:
        json.dump(d, tmp, indent=2)
        tmp.write("\n")
        tmp.flush()
        os.fsync(tmp.fileno())
        tmp.close()
        os.replace(tmp.name, path)
    except Exception:
        try:
            os.unlink(tmp.name)
        except Exception:
            pass
        sys.exit(0)

for line in report_lines:
    print(line)
PY
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

_validate_resource() {
  local resource="$1"
  # Accept dot-prefixed names (e.g. .mcp.json, .credentials.json) but disallow
  # path separators, globs, and `..` traversal so that `hats link/unlink` can
  # only target files directly under $BASE_DIR.
  case "$resource" in
    ''|*/*|*\**|*\?*|..|.) die "Invalid resource name '$resource'." ;;
  esac
  [[ "$resource" =~ ^\.?[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die "Invalid resource name '$resource'."
}

_link_resource() {
  local name="$1" resource="$2"
  local acct_dir
  acct_dir=$(_account_dir "$name")

  _validate_resource "$resource"
  _is_isolated "$resource" && die "'$resource' is always isolated and cannot be linked."
  [ -e "$BASE_DIR/$resource" ] || [ -L "$BASE_DIR/$resource" ] || die "Resource '$resource' not found in base."

  if [ -L "$acct_dir/$resource" ]; then
    local target
    target=$(readlink "$acct_dir/$resource")
    [[ "$target" == *"base/$resource"* ]] && die "'$resource' is already linked to base."
  fi

  # `:?` guards ensure rm -rf never expands to / even if vars are ever empty.
  # `_validate_resource` + `_account_dir` should make that impossible, but
  # defensive.
  rm -rf "${acct_dir:?}/${resource:?}"
  ln -s "../base/$resource" "$acct_dir/$resource"
  echo "Linked $CURRENT_PROVIDER/$name/$resource -> base/$resource"
}

_unlink_resource() {
  local name="$1" resource="$2"
  local acct_dir
  acct_dir=$(_account_dir "$name")

  _validate_resource "$resource"
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
  # File path passed via argv, not string-interpolated into the python source,
  # so a path containing quotes / shell metacharacters cannot break out into
  # Python code execution.
  python3 - "$file" <<'PYEOF' 2>/dev/null
import json, datetime, sys
try:
    d = json.load(open(sys.argv[1]))
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
PYEOF
}

_token_info_codex() {
  local file="$1"
  local acct_dir
  acct_dir=$(dirname "$file")
  local store="unknown"
  if [ -f "$acct_dir/config.toml" ]; then
    store=$(grep '^cli_auth_credentials_store' "$acct_dir/config.toml" 2>/dev/null | head -1 | sed -E 's/^[^=]*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/' | tr -d '[:space:]')
  fi
  [ -n "$store" ] || store="unset"

  # File path passed via argv, not string-interpolated (see _token_info_claude).
  python3 - "$file" <<'PYEOF' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    tokens = d.get('tokens') or {}
    print('present=True')
    print(f"account_id={tokens.get('account_id', 'unknown')}")
except Exception as e:
    print(f'error={e}')
PYEOF
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

  # Parse the key=value lines from _token_info using bash built-ins — BSD
  # grep has no -P / \K so the prior `grep -oP 'key=\K...'` pattern only
  # worked on GNU grep. Reading into variables via a while-read loop keeps
  # parsing portable while preserving existing semantics (exp_date keeps the
  # date portion only, matching the old `[^ ]+` boundary).
  local expired="" has_refresh="" has_rc="" exp_date="" store="" account_id="" error=""
  local _key _val
  while IFS='=' read -r _key _val; do
    case "$_key" in
      error)           error="$_val" ;;
      expired)         expired="$_val" ;;
      refresh)         has_refresh="$_val" ;;
      remote_control)  has_rc="$_val" ;;
      expires)         exp_date="${_val%% *}" ;;
      store)           store="$_val" ;;
      account_id)      account_id="$_val" ;;
    esac
  done <<< "$info"

  if [ -n "$error" ]; then
    echo "ERROR: $error"
    return
  fi

  case "$CURRENT_PROVIDER" in
    claude)
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
    _audit_log "add" "account" "$name"
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
  _audit_log "remove" "account" "$name"

  if [ "$name" = "$default" ]; then
    rm -f "$RUNTIME_DIR"
    local new_default
    new_default=$(_accounts | head -1)
    if [ -n "$new_default" ]; then
      _set_default "$new_default"
      echo "New default: $new_default"
      _audit_log "default" "account" "$new_default" "reason" "previous_default_removed"
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
  _audit_log "rename" "from" "$old_name" "to" "$new_name"

  if [ "$old_name" = "$(_default_account)" ]; then
    _set_default "$new_name"
    echo "Default account set to '$new_name'."
    echo "$RUNTIME_DIR -> $PROVIDER_DIR/$new_name/"
    _audit_log "default" "account" "$new_name" "reason" "renamed_from_default"
  fi
}

_list_usage() {
  cat <<EOF
Usage: $(_hats_cmd_prefix) list [--rc-only] [--expired] [--provider <claude|codex>]

  --rc-only            Show only accounts whose token carries the Claude Code
                       remote-control scope. Codex accounts have no RC concept
                       so they never match.
  --expired            Show only accounts whose token is past expiry. Codex
                       accounts (token expiry not surfaced) never match.
  --provider <name>    Override the provider for this invocation (equivalent to
                       '$(_hats_cmd_prefix_of "\$name") list').
EOF
}

_hats_cmd_prefix_of() {
  # Like _hats_cmd_prefix but for an explicitly-named provider, used in help
  # strings where CURRENT_PROVIDER may not be the relevant one yet.
  case "${1:-claude}" in
    claude) echo "hats" ;;
    codex)  echo "hats codex" ;;
    *)      echo "hats $1" ;;
  esac
}

_account_passes_list_filters() {
  # Returns 0 (pass) if the named account satisfies every active filter,
  # 1 otherwise. Accounts with no credential file or parse errors fail any
  # token-predicate filter (they cannot be proved to match), but pass if no
  # predicate filter is active.
  local name="$1" want_rc="$2" want_expired="$3"
  [ "$want_rc" = "0" ] && [ "$want_expired" = "0" ] && return 0

  local cfile
  cfile=$(_credential_file "$name")
  [ -f "$cfile" ] || return 1

  local info has_rc="" is_expired=""
  info=$(_token_info "$cfile" 2>/dev/null)
  local _key _val
  while IFS='=' read -r _key _val; do
    case "$_key" in
      remote_control) has_rc="$_val" ;;
      expired)        is_expired="$_val" ;;
    esac
  done <<< "$info"

  [ "$want_rc" = "1" ]      && [ "$has_rc" != "True" ]      && return 1
  [ "$want_expired" = "1" ] && [ "$is_expired" != "True" ]  && return 1
  return 0
}

cmd_list() {
  local want_rc=0 want_expired=0 override_provider=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --rc-only)  want_rc=1 ;;
      --expired)  want_expired=1 ;;
      --provider)
        shift || die "$(_list_usage)"
        [ $# -gt 0 ] || die "$(_list_usage)"
        override_provider="$1"
        ;;
      --provider=*)
        override_provider="${1#--provider=}"
        ;;
      -h|--help)  _list_usage; return 0 ;;
      *) die "Unknown list flag '$1'"$'\n'"$(_list_usage)" ;;
    esac
    shift || true
  done

  # --provider rewires the dispatch. Validate first, then call _configure_provider
  # so downstream helpers resolve against the correct tree.
  if [ -n "$override_provider" ]; then
    _is_supported_provider "$override_provider" \
      || die "Unsupported provider '$override_provider'. Supported: claude, codex"
    _configure_provider "$override_provider"
  fi

  echo "hats v$VERSION — $PROVIDER_TITLE Accounts"
  echo "======================================="

  # Describe the active filter set so a zero-result output isn't mysterious.
  local filter_desc=""
  [ "$want_rc" = "1" ]      && filter_desc="$filter_desc --rc-only"
  [ "$want_expired" = "1" ] && filter_desc="$filter_desc --expired"
  [ -n "$filter_desc" ] && echo "Filters:$filter_desc"

  echo ""

  local default
  default=$(_default_account)
  local count=0 matched=0

  for name in $(_accounts); do
    count=$((count + 1))
    if _account_passes_list_filters "$name" "$want_rc" "$want_expired"; then
      matched=$((matched + 1))
      _show_account_status "$name" "$default"
    fi
  done

  if [ "$count" -eq 0 ]; then
    echo "  No accounts found."
    echo "  Run '$(_hats_cmd_prefix) add <name>' to create one."
  elif [ "$matched" -eq 0 ]; then
    echo "  No accounts matched the filters ($count total)."
  fi

  echo ""
  if [ -n "$filter_desc" ]; then
    echo "  $matched of $count account(s) matched"
  else
    echo "  $count account(s)"
  fi
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
  _audit_log "default" "account" "$name"
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
  # Log the swap BEFORE exec — _run_provider_command exec-chains into the
  # provider CLI, so anything after this line doesn't execute in the
  # parent shell.
  _audit_log "swap" "account" "$name"
  _run_provider_command "$acct_dir" "$@"
}

cmd_link() {
  local name="${1:-}" resource="${2:-}"
  [ -z "$name" ] || [ -z "$resource" ] && die "Usage: $(_hats_cmd_prefix) link <account> <resource>"

  _account_exists "$name" || die "Account '$name' not found."
  _link_resource "$name" "$resource"
  _audit_log "link" "account" "$name" "resource" "$resource"
}

cmd_unlink() {
  local name="${1:-}" resource="${2:-}"
  [ -z "$name" ] || [ -z "$resource" ] && die "Usage: $(_hats_cmd_prefix) unlink <account> <resource>"

  _account_exists "$name" || die "Account '$name' not found."
  _unlink_resource "$name" "$resource"
  _audit_log "unlink" "account" "$name" "resource" "$resource"
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
  # Explicit rc=0: when linked_any=true the previous `[ false ] && echo` short-
  # circuits to rc=1, which would leak out as the function's return code under
  # `set -e` callers. Normal `hats status` on a typical account always has
  # linked resources, so without this the happy path returned rc=1.
  return 0
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

  if [ "$CURRENT_PROVIDER" = "claude" ]; then
    local dedupe_report
    dedupe_report=$(_dedupe_claude_hook_registrations)
    if [ -n "$dedupe_report" ]; then
      while IFS=$'\t' read -r _ev _m _n; do
        [ -n "$_ev" ] || continue
        echo "  deduped base/settings.json hooks: event=$_ev matcher=$_m removed=$_n"
      done <<< "$dedupe_report"
    fi
  fi

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
      if [[ "$bn" == "." || "$bn" == ".." ]]; then continue; fi

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
      if [ ! -e "$base_item" ] && [ ! -L "$base_item" ]; then continue; fi
      local bn
      bn=$(basename "$base_item")
      if [[ "$bn" == "." || "$bn" == ".." ]]; then continue; fi
      if _is_isolated "$bn"; then continue; fi
      if ! _is_shared_by_default "$bn"; then continue; fi

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
      current_target=$(_realpath "$RUNTIME_DIR")
      local expected_resolved
      expected_resolved=$(_realpath "$expected_target")
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

_account_token_mtime_age_days() {
  # Emit the credential file's mtime in ISO-8601 and its age in whole days.
  # Format: `mtime=<YYYY-MM-DD>\nage_days=<int>`. Empty output if the file is
  # missing — callers treat that as "no data" and skip the metrics line.
  # Portable across GNU + BSD stat (falls back to python3 for age arithmetic).
  local cfile="$1"
  [ -f "$cfile" ] || return 0
  python3 - "$cfile" <<'PYEOF' 2>/dev/null
import os, sys, time
try:
    st = os.stat(sys.argv[1])
    age = int((time.time() - st.st_mtime) // 86400)
    iso = time.strftime('%Y-%m-%d', time.localtime(st.st_mtime))
    print(f'mtime={iso}')
    print(f'age_days={age}')
except Exception:
    pass
PYEOF
}

_doctor_metrics_section() {
  # Invoked when `hats doctor --metrics` is used. Prints a per-account
  # freshness line using the credential file's mtime (a strong proxy for
  # "last time this account was actually used", since hats saves back the
  # refreshed token at end-of-session). Flags dormant accounts so the
  # operator can clean up before a long session hits a surprise re-auth.
  echo ""
  echo "Metrics — token freshness:"

  local default
  default=$(_default_account)
  local any=0

  for name in $(_accounts); do
    any=1
    local cfile
    cfile=$(_credential_file "$name")

    local marker=" "
    [ "$name" = "$default" ] && marker="*"

    if [ ! -f "$cfile" ]; then
      printf "  %s %-12s NO CREDENTIALS\n" "$marker" "$name"
      continue
    fi

    local info mtime="" age_days=""
    info=$(_account_token_mtime_age_days "$cfile")
    local _key _val
    while IFS='=' read -r _key _val; do
      case "$_key" in
        mtime)    mtime="$_val" ;;
        age_days) age_days="$_val" ;;
      esac
    done <<< "$info"

    if [ -z "$age_days" ]; then
      printf "  %s %-12s mtime unreadable\n" "$marker" "$name"
      continue
    fi

    # Dormancy thresholds: >30d WARN, >90d stronger (shows in tag). Thresholds
    # picked to match how Claude Code tokens drift in practice — active daily
    # use keeps mtime within a day, weekly use within 7d, and anything over
    # 30d is usually an account that's been abandoned without `hats remove`.
    local tag=""
    if [ "$age_days" -gt 90 ]; then
      tag=" WARN very dormant"
    elif [ "$age_days" -gt 30 ]; then
      tag=" WARN dormant"
    fi

    printf "  %s %-12s last refresh %3sd ago (%s)%s\n" \
      "$marker" "$name" "$age_days" "$mtime" "$tag"
  done

  if [ "$any" -eq 0 ]; then
    echo "  (no accounts)"
  fi
}

cmd_doctor() {
  local show_metrics=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --metrics) show_metrics=1 ;;
      -h|--help)
        cat <<EOF
Usage: $(_hats_cmd_prefix) doctor [--metrics]

Read-only health check for the hats layout. With --metrics, also prints
per-account token-freshness (credential-file mtime + dormancy WARN for
accounts untouched in >30d / >90d).
EOF
        return 0
        ;;
      *) die "Unknown doctor flag '$1'. Try 'hats doctor --help'." ;;
    esac
    shift || true
  done

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

  # 2b. Base config JSON validity — claude-code silently fails to load an invalid
  # settings.json / hooks.json / .mcp.json; surface parse errors loudly.
  if [ "$CURRENT_PROVIDER" = "claude" ] && command -v python3 >/dev/null 2>&1; then
    local cfg_bn
    for cfg_bn in settings.json hooks.json .mcp.json; do
      local cfg_path="$BASE_DIR/$cfg_bn"
      [ -f "$cfg_path" ] || continue
      if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$cfg_path" 2>/dev/null; then
        echo "  OK   base/$cfg_bn parses as JSON"
      else
        echo "  FAIL base/$cfg_bn is not valid JSON (claude-code will reject it)"
        issues=$((issues + 1))
      fi
    done
  fi

  # 2d. Hook command paths in base/settings.json — claude-code silently fails
  # at tool-call time if a referenced hook command path doesn't exist or
  # isn't executable. Walk the hooks.* tree and check each unique command.
  if [ "$CURRENT_PROVIDER" = "claude" ] \
      && [ -f "$BASE_DIR/settings.json" ] \
      && command -v python3 >/dev/null 2>&1; then
    local missing_hooks=0 hook_path expanded
    while IFS= read -r hook_path; do
      [ -n "$hook_path" ] || continue
      # Expand a leading ~ so we can stat the path. Other shell-level
      # expansions (env vars, etc.) are left to claude-code at runtime.
      expanded="${hook_path/#\~/$HOME}"
      if [ ! -e "$expanded" ]; then
        echo "  FAIL hook command missing: $hook_path (referenced in base/settings.json)"
        missing_hooks=$((missing_hooks + 1))
        issues=$((issues + 1))
      elif [ ! -x "$expanded" ]; then
        echo "  FAIL hook command not executable: $hook_path (chmod +x it)"
        missing_hooks=$((missing_hooks + 1))
        issues=$((issues + 1))
      fi
    done < <(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
seen = set()
for event_items in (d.get("hooks") or {}).values():
    if not isinstance(event_items, list):
        continue
    for item in event_items:
        for hook in (item.get("hooks") or []):
            cmd = hook.get("command")
            if cmd:
                seen.add(cmd)
for c in sorted(seen):
    print(c)
' "$BASE_DIR/settings.json" 2>/dev/null)
    if [ "$missing_hooks" -eq 0 ]; then
      echo "  OK   hook commands in base/settings.json all resolve + executable"
    fi
  fi

  # 2e. Duplicate hook entries in base/settings.json — claude-code will run
  # an identical (matcher, command-set) hook multiple times if registered
  # multiple times under the same event. Usually benign but wastes cycles and
  # is almost always a misconfiguration from repeated appends.
  if [ "$CURRENT_PROVIDER" = "claude" ] \
      && [ -f "$BASE_DIR/settings.json" ] \
      && command -v python3 >/dev/null 2>&1; then
    local dup_out
    dup_out=$(python3 -c '
import json, sys
from collections import Counter
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for event_name, event_items in (d.get("hooks") or {}).items():
    if not isinstance(event_items, list):
        continue
    fingerprints = []
    for item in event_items:
        matcher = item.get("matcher", "") or ""
        cmds = tuple(sorted(
            (h.get("command") or "") for h in (item.get("hooks") or [])
        ))
        fingerprints.append((matcher, cmds))
    for (matcher, cmds), n in Counter(fingerprints).items():
        if n > 1:
            m = matcher if matcher else "(no-matcher)"
            print(f"{event_name}\t{m}\t{n}")
' "$BASE_DIR/settings.json" 2>/dev/null)
    if [ -n "$dup_out" ]; then
      while IFS=$'\t' read -r event_name matcher count; do
        [ -n "$event_name" ] || continue
        echo "  WARN duplicate hook registration: event=$event_name matcher=$matcher count=$count (run '$(_hats_cmd_prefix) fix' to dedupe)"
        warnings=$((warnings + 1))
      done <<< "$dup_out"
    else
      echo "  OK   no duplicate hook registrations in base/settings.json"
    fi
  fi

  # 2f. Symlink-target validation — any symlink in base/ that resolves
  # outside $HOME is flagged. Threat model: a malicious or mistaken symlink
  # at base/settings.json pointing to /etc/shadow (or similar) would be
  # propagated into every account via `hats fix` and inadvertently read by
  # claude-code. This surfaces such cases for human audit. Targets already
  # inside $HOME pass silently — many legitimate setups symlink base/agents
  # / base/skills to a user-owned scripts directory outside $HATS_DIR.
  local suspicious_links=0
  for item in "$BASE_DIR"/* "$BASE_DIR"/.*; do
    [ -L "$item" ] || continue
    local bn resolved
    bn=$(basename "$item")
    if [[ "$bn" == "." || "$bn" == ".." ]]; then continue; fi
    resolved=$(_realpath "$item" || true)
    [ -n "$resolved" ] || continue
    case "$resolved" in
      "$HOME"|"$HOME"/*)
        ;;  # inside $HOME — assumed user-owned, pass
      *)
        echo "  WARN base/$bn symlink resolves outside \$HOME: $resolved"
        suspicious_links=$((suspicious_links + 1))
        warnings=$((warnings + 1))
        ;;
    esac
  done
  [ "$suspicious_links" -eq 0 ] && echo "  OK   all base symlinks resolve inside \$HOME"

  # 2c. Orphan isolated resources in base — anything matching ISOLATED_PATTERNS
  # should only exist per-account, never in base. A stray `.credentials.json`
  # or `auth.json` in base/ is a migration artifact and a potential credential-leak
  # risk (every account would silently inherit these tokens on next `hats fix`).
  local orphans=0
  for item in "$BASE_DIR"/* "$BASE_DIR"/.*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    local bn
    bn=$(basename "$item")
    [[ "$bn" == "." || "$bn" == ".." ]] && continue
    if _is_isolated "$bn"; then
      echo "  WARN orphan isolated resource in base: $bn (should only exist per-account)"
      orphans=$((orphans + 1))
      warnings=$((warnings + 1))
    fi
  done
  [ "$orphans" -eq 0 ] && echo "  OK   no orphan isolated resources in base"

  # 3. Default-account runtime symlink (~/.claude or ~/.codex).
  local default
  default=$(_default_account)
  if [ -z "$default" ]; then
    echo "  WARN no default account configured (bare '$RUNTIME_COMMAND' won't resolve)"
    warnings=$((warnings + 1))
  elif [ -L "$RUNTIME_DIR" ]; then
    local current_target expected_resolved
    current_target=$(_realpath "$RUNTIME_DIR" || true)
    expected_resolved=$(_realpath "$PROVIDER_DIR/$default" || true)
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

  if [ "$show_metrics" -eq 1 ]; then
    _doctor_metrics_section
  fi

  echo "Done. $issues issue(s), $warnings warning(s)."
  [ "$issues" -eq 0 ]
}

cmd_completion() {
  local shell="${1:-}"
  case "$shell" in
    bash) _print_bash_completion ;;
    zsh)  _print_zsh_completion ;;
    ''|-h|--help)
      cat <<EOF
Usage: $(_hats_cmd_prefix) completion <bash|zsh>

Emits a shell-completion script to stdout. Source or eval the output to
enable tab completion for the 'hats' command.

  # bash (add to ~/.bashrc):
  eval "\$(hats completion bash)"

  # zsh (add to ~/.zshrc):
  eval "\$(hats completion zsh)"
EOF
      [ -z "$shell" ] && exit 0 || return 0
      ;;
    *) die "Usage: $(_hats_cmd_prefix) completion <bash|zsh>" ;;
  esac
}

_print_bash_completion() {
  cat <<'BASH_COMPLETION'
# hats — bash tab completion
# Emitted by `hats completion bash`. Source via `eval "$(hats completion bash)"`.
_hats_completion() {
  local cur prev words cword
  _init_completion 2>/dev/null || {
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    words=("${COMP_WORDS[@]}")
    cword=$COMP_CWORD
  }

  local providers="claude codex"
  local cmds="init add remove rm rename mv list ls swap default link unlink status shell-init fix doctor completion providers audit version help"
  local first="${words[1]:-}"
  local second="${words[2]:-}"

  local provider="claude"
  local cmd_idx=1
  if [[ " $providers " == *" $first "* ]]; then
    provider="$first"
    cmd_idx=2
  fi
  local cmd="${words[$cmd_idx]:-}"

  # Position 1: providers + commands (commands repeated for backward-compat).
  if [ "$cword" -eq 1 ]; then
    COMPREPLY=( $(compgen -W "$providers $cmds" -- "$cur") )
    return
  fi

  # Position 2: if position 1 was a provider, offer commands; else offer
  # arguments for the command at position 1.
  if [ "$cword" -eq 2 ] && [[ " $providers " == *" $first "* ]]; then
    COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
    return
  fi

  # Commands that take an account name as their first arg.
  case "$cmd" in
    add|remove|rm|rename|mv|swap|default|link|unlink|status)
      local root="${HATS_DIR:-$HOME/.hats}/$provider"
      local accts=""
      if [ -d "$root" ]; then
        for d in "$root"/*/; do
          [ -d "$d" ] || continue
          local n; n=$(basename "$d")
          [ "$n" = "base" ] && continue
          accts="$accts $n"
        done
      fi
      COMPREPLY=( $(compgen -W "$accts" -- "$cur") )
      ;;
    list|ls)
      # `--provider <name>` takes an arg — offer the provider list when that
      # was the previous word. Otherwise offer the flag set itself.
      if [ "$prev" = "--provider" ]; then
        COMPREPLY=( $(compgen -W "$providers" -- "$cur") )
      else
        COMPREPLY=( $(compgen -W "--rc-only --expired --provider --help" -- "$cur") )
      fi
      ;;
    doctor)
      COMPREPLY=( $(compgen -W "--metrics --help" -- "$cur") )
      ;;
    completion)
      COMPREPLY=( $(compgen -W "bash zsh" -- "$cur") )
      ;;
    *) COMPREPLY=() ;;
  esac
}
complete -F _hats_completion hats
BASH_COMPLETION
}

_print_zsh_completion() {
  cat <<'ZSH_COMPLETION'
# hats — zsh tab completion
# Emitted by `hats completion zsh`. Source via `eval "$(hats completion zsh)"`.
_hats() {
  local -a cmds providers
  providers=(claude codex)
  cmds=(
    'init:Initialize hats for the active provider'
    'add:Create a new account'
    'remove:Remove an account'
    'rm:Alias for remove'
    'rename:Rename an account'
    'mv:Alias for rename'
    'list:Show all accounts'
    'ls:Alias for list'
    'swap:Run provider CLI with account home'
    'default:Get or set the default account'
    'link:Share a resource with base'
    'unlink:Isolate a resource'
    'status:Show linked vs isolated resources'
    'shell-init:Emit shell functions for your config'
    'fix:Repair symlinks + verify auth'
    'doctor:Read-only health check'
    'completion:Emit shell-completion script (bash|zsh)'
    'providers:Show supported providers'
    'audit:Read the hats audit log (opt-in via HATS_AUDIT=1)'
    'version:Show version'
    'help:Show help'
  )

  _arguments -C \
    '1: :->first' \
    '2: :->second' \
    '*: :->rest'

  local provider=claude
  local cmd_idx=1
  if (( ${providers[(Ie)$words[2]]} )); then
    provider=$words[2]
    cmd_idx=2
  fi
  local cmd=$words[cmd_idx+1]

  case $state in
    first)
      _describe 'hats commands' cmds
      _values 'provider' ${providers[@]}
      ;;
    second)
      if (( ${providers[(Ie)$words[2]]} )); then
        _describe 'hats commands' cmds
      else
        _hats_complete_arg $words[2] $provider
      fi
      ;;
    rest)
      _hats_complete_arg $cmd $provider
      ;;
  esac
}

_hats_complete_arg() {
  local cmd="$1" provider="$2"
  local root="${HATS_DIR:-$HOME/.hats}/$provider"
  case "$cmd" in
    add|remove|rm|rename|mv|swap|default|link|unlink|status)
      local -a accts
      [[ -d "$root" ]] || return
      for d in "$root"/*/; do
        [[ -d "$d" ]] || continue
        local n="${d:h:t}"
        [[ "$n" == "base" ]] && continue
        accts+=("$n")
      done
      _describe 'account' accts
      ;;
    list|ls)
      # `--provider <name>` takes an arg; offer provider names when that flag
      # was the previous word, otherwise offer the flag set itself.
      if [[ "$words[CURRENT-1]" == "--provider" ]]; then
        local -a provs; provs=(claude codex)
        _describe 'provider' provs
      else
        local -a list_flags
        list_flags=(
          '--rc-only:Filter to remote-control-scoped tokens'
          '--expired:Filter to past-expiry tokens'
          '--provider:Override the provider (claude|codex)'
          '--help:Show list-flag reference'
        )
        _describe 'list flag' list_flags
      fi
      ;;
    doctor)
      local -a doctor_flags
      doctor_flags=(
        '--metrics:Add per-account token-freshness section'
        '--help:Show doctor-flag reference'
      )
      _describe 'doctor flag' doctor_flags
      ;;
    completion)
      local -a shells; shells=(bash zsh)
      _describe 'shell' shells
      ;;
  esac
}

compdef _hats hats
ZSH_COMPLETION
}

cmd_providers() {
  echo "Supported providers:"
  echo "  claude"
  echo "  codex"
  echo ""
  echo "Default provider: $(_default_provider)"
}

cmd_audit() {
  # Reader for the opt-in audit log. Prints the last N entries
  # (default 20) in a human-friendly form. Passes through `--raw` to
  # emit the underlying JSONL unmodified for piping into `jq` / other
  # tools. Non-fatal when the log doesn't exist yet.
  local n=20
  local raw=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -n)
        shift || die "Usage: hats audit [-n <count>] [--raw]"
        [ $# -gt 0 ] || die "Usage: hats audit [-n <count>] [--raw]"
        n="$1"
        ;;
      --raw) raw=1 ;;
      -h|--help)
        cat <<EOF
Usage: hats audit [-n <count>] [--raw]

Read the hats audit log. Opt-in via HATS_AUDIT=1 (writes to
\$HATS_AUDIT_LOG, default $HATS_DIR/audit.log). Events recorded:
add, remove, rename, default, link, unlink, swap.

  -n <count>   Show only the last <count> entries (default 20).
  --raw        Emit JSONL unmodified, for jq / log shippers.
EOF
        return 0
        ;;
      *) die "Unknown flag: $1. See 'hats audit --help'." ;;
    esac
    shift || true
  done

  if [ ! -f "$HATS_AUDIT_LOG" ]; then
    echo "No audit log at $HATS_AUDIT_LOG."
    if [ "$HATS_AUDIT" != "1" ]; then
      echo "Audit logging is disabled. Enable with: export HATS_AUDIT=1"
    fi
    return 0
  fi

  if [ "$raw" -eq 1 ]; then
    tail -n "$n" "$HATS_AUDIT_LOG"
    return 0
  fi

  # Pretty-print: one line per event, fixed-width columns. python3 is
  # already a hats hard-dep (token inspection) so reusing it for JSON
  # decode is consistent with the rest of the script. Note: argv-style
  # invocation (log path + count passed as sys.argv), heredoc is
  # SINGLE-quoted so no shell substitution inside. Don't pipe tail |
  # python3 - << heredoc — the heredoc collides with the pipe on stdin.
  python3 - "$HATS_AUDIT_LOG" "$n" <<'PYEOF' 2>/dev/null || true
import json, sys
from collections import deque
log_path, n_str = sys.argv[1], sys.argv[2]
try:
    n = int(n_str)
except ValueError:
    n = 20
# Efficient tail: deque with maxlen keeps only the last N lines in memory
# even on huge logs.
with open(log_path, "r", encoding="utf-8") as f:
    lines = deque(f, maxlen=n)
for raw in lines:
    raw = raw.strip()
    if not raw:
        continue
    try:
        e = json.loads(raw)
    except Exception:
        # Skip malformed lines rather than aborting — audit readers
        # must be forgiving of partial writes.
        continue
    ts = e.pop("ts", "?")
    event = e.pop("event", "?")
    provider = e.pop("provider", "?")
    user = e.pop("user", "?")
    extras = " ".join(f"{k}={v}" for k, v in e.items())
    print(f"{ts}  {user:<10}  {provider:<6}  {event:<8}  {extras}")
PYEOF
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
  list [flags]         Show all accounts and auth status
                       Flags: --rc-only --expired --provider <claude|codex>

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
  doctor [--metrics]   Read-only health check (tooling, layout, symlinks, permissions)
                       --metrics adds per-account token-freshness readout
  completion <shell>   Emit tab-completion script for bash or zsh
  providers            Show supported providers
  audit [-n N] [--raw] Read the hats audit log (opt-in via HATS_AUDIT=1)
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
  NO_COLOR             Disable colored output (https://no-color.org)
  HATS_NO_COLOR        Same as NO_COLOR, hats-scoped alias
  HATS_AUDIT           Set to 1 to enable the audit log (default: 0 / off)
  HATS_AUDIT_LOG       Audit log path (default: \$HATS_DIR/audit.log)

Global flags:
  --no-color           Disable colored output for this invocation

Config: $HATS_CONFIG
EOF
}

# ── Main ─────────────────────────────────────────────────────────

_migrate_legacy_default

# Parse global --no-color flag before provider/command dispatch so every
# subcommand can opt into colorized output via _should_color.
HATS_NO_COLOR="${HATS_NO_COLOR:-0}"
args=()
for a in "$@"; do
  case "$a" in
    --no-color) HATS_NO_COLOR=1 ;;
    *) args+=("$a") ;;
  esac
done
set -- "${args[@]+"${args[@]}"}"
export HATS_NO_COLOR

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
  list|ls)          shift; cmd_list "$@" ;;
  swap)             shift; cmd_swap "$@" ;;
  default)          cmd_default "${2:-}" ;;
  link)             cmd_link "${2:-}" "${3:-}" ;;
  unlink)           cmd_unlink "${2:-}" "${3:-}" ;;
  status)           cmd_status "${2:-}" ;;
  shell-init)       shift; cmd_shell_init "$@" ;;
  fix)              cmd_fix | _colorize_stream; exit "${PIPESTATUS[0]}" ;;
  doctor)           shift; cmd_doctor "$@" | _colorize_stream; exit "${PIPESTATUS[0]}" ;;
  completion)       cmd_completion "${2:-}" ;;
  providers)        cmd_providers ;;
  audit)            shift; cmd_audit "$@" ;;
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
