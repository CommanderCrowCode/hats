#!/usr/bin/env bash
# tests/smoke.sh — non-interactive regression check for the `hats` CLI.
#
# Isolates via an HATS_DIR override so it never touches ~/.hats on the dev
# machine. Exercises the command surface (version/help/init/list/default/doctor
# /fix) and verifies the JSON-validity check in `hats doctor` actually catches
# corruption. Exits 0 on all-pass, 1 on any fail.
#
# Run directly:
#   ./tests/smoke.sh
#
# Or from the repo root:
#   tests/smoke.sh

set -euo pipefail

HATS_SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/hats"
[ -x "$HATS_SCRIPT" ] || { echo "missing or non-executable hats at $HATS_SCRIPT" >&2; exit 1; }

# Sandbox both HOME and HATS_DIR so the suite never touches the user's real
# `~/.claude` / `~/.codex` runtime symlinks. hats resolves $HOME/.claude
# dynamically (via `$HOME/.claude` in `_configure_provider`), so overriding HOME
# is the cleanest way to isolate. The real shell env is unaffected — these are
# only exported in this subshell.
SANDBOX_ROOT="$(mktemp -d -t hats-smoke-XXXXXX)"
export HOME="$SANDBOX_ROOT"
export HATS_DIR="$SANDBOX_ROOT/.hats"

cleanup() { rm -rf "$SANDBOX_ROOT"; }
trap cleanup EXIT

pass=0
fail=0
say() { printf '[smoke] %s\n' "$*"; }
ok()  { pass=$((pass + 1)); printf '[smoke]   PASS %s\n' "$*"; }
die() { fail=$((fail + 1)); printf '[smoke]   FAIL %s\n' "$*" >&2; }

# ── Tests ─────────────────────────────────────────────────────────

test_version() {
  local out
  out=$("$HATS_SCRIPT" version)
  case "$out" in
    "hats "*) ok "version prints 'hats <version>'" ;;
    *) die "version output unexpected: $out" ;;
  esac
}

test_help() {
  if "$HATS_SCRIPT" help >/dev/null 2>&1; then
    ok "help exits 0"
  else
    die "help exited nonzero"
  fi
}

test_init_creates_layout() {
  "$HATS_SCRIPT" init >/dev/null
  if [ -d "$HATS_DIR/claude/base" ] && [ -f "$HATS_DIR/config.toml" ]; then
    ok "init creates claude/base + config.toml"
  else
    die "init did not create expected layout"
  fi
}

test_list_empty_does_not_crash() {
  if "$HATS_SCRIPT" list >/dev/null 2>&1; then
    ok "list exits 0 with no accounts"
  else
    die "list crashed on empty state"
  fi
}

test_fixture_account_and_default() {
  # Manually stage a minimal account (simulates `hats add foo` without /login).
  local acct="$HATS_DIR/claude/foo"
  mkdir -p "$acct"
  : > "$acct/.credentials.json"
  chmod 600 "$acct/.credentials.json"
  echo '{}' > "$acct/.claude.json"

  # Setting default writes default_claude to config.toml + maintains $HOME/.claude.
  local out
  out=$("$HATS_SCRIPT" default foo 2>&1)
  case "$out" in
    *foo*) ok "'default foo' accepts fixture account" ;;
    *) die "'default foo' unexpected output: $out" ;;
  esac

  # Confirm the default was persisted.
  if grep -q '^default_claude[[:space:]]*=[[:space:]]*"foo"' "$HATS_DIR/config.toml"; then
    ok "default_claude persisted in config.toml"
  else
    die "default_claude not persisted"
  fi
}

test_fix_on_fresh_sandbox() {
  # Regression test for issue #3: `hats fix` silently aborting after the
  # header line on a fresh sandbox. After the _ensure_provider_defaults fix,
  # it must complete and reach the "Done." tail.
  local out rc=0
  out=$("$HATS_SCRIPT" fix 2>&1) || rc=$?
  case "$out" in
    *Done.*)
      ok "fix reaches 'Done.' on fresh sandbox (rc=$rc)"
      ;;
    *)
      die "fix aborted early (rc=$rc output=$out)"
      ;;
  esac
}

test_doctor_runs_after_fixture() {
  local rc=0
  "$HATS_SCRIPT" doctor >/dev/null 2>&1 || rc=$?
  # In the sandboxed HATS_DIR the ~/.claude symlink on the host still points
  # elsewhere, which doctor will flag — accept rc!=0 as long as the command
  # ran to completion and didn't crash with a bash error.
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
    ok "doctor completes (rc=$rc, issues-or-clean)"
  else
    die "doctor exited with unexpected code $rc"
  fi
}

test_doctor_catches_invalid_json() {
  local base="$HATS_DIR/claude/base"
  local cfg="$base/hooks.json"

  # Capture output separately from pipeline so SIGPIPE / pipefail quirks don't
  # mask real results.
  echo '{}' > "$cfg"
  local out_valid
  out_valid=$("$HATS_SCRIPT" doctor 2>/dev/null || true)

  echo '{broken' > "$cfg"
  local out_broken
  out_broken=$("$HATS_SCRIPT" doctor 2>/dev/null || true)

  # Restore a valid state so any subsequent tests don't inherit corruption.
  echo '{}' > "$cfg"

  local rc_valid=1 rc_broken=1
  echo "$out_valid"  | grep -q "OK   base/hooks.json parses as JSON" && rc_valid=0
  echo "$out_broken" | grep -q "FAIL base/hooks.json is not valid JSON" && rc_broken=0

  if [ "$rc_valid" -eq 0 ] && [ "$rc_broken" -eq 0 ]; then
    ok "doctor validates base/hooks.json JSON"
  else
    die "doctor json validity check broken (valid_rc=$rc_valid broken_rc=$rc_broken)"
  fi
}

test_doctor_catches_missing_hook_command() {
  local base="$HATS_DIR/claude/base"
  local cfg="$base/settings.json"
  mkdir -p "$base"

  # Reference a hook command that definitely does not exist.
  cat > "$cfg" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {"type": "command", "command": "/tmp/hats-smoke-nonexistent-hook.sh"}
        ]
      }
    ]
  }
}
EOF

  local out_bad
  out_bad=$("$HATS_SCRIPT" doctor 2>/dev/null || true)

  # Now point it at a real executable (/bin/sh).
  cat > "$cfg" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {"type": "command", "command": "/bin/sh"}
        ]
      }
    ]
  }
}
EOF

  local out_good
  out_good=$("$HATS_SCRIPT" doctor 2>/dev/null || true)

  # Restore baseline (empty hooks block so no other tests are affected).
  echo '{}' > "$cfg"

  local rc_bad=1 rc_good=1
  echo "$out_bad"  | grep -q "FAIL hook command missing: /tmp/hats-smoke-nonexistent-hook.sh" && rc_bad=0
  echo "$out_good" | grep -q "OK   hook commands in base/settings.json all resolve" && rc_good=0

  if [ "$rc_bad" -eq 0 ] && [ "$rc_good" -eq 0 ]; then
    ok "doctor validates hook command paths"
  else
    die "hook-command check broken (bad_rc=$rc_bad good_rc=$rc_good)"
  fi
}

test_doctor_catches_duplicate_hooks() {
  local base="$HATS_DIR/claude/base"
  local cfg="$base/settings.json"
  mkdir -p "$base"

  # settings.json with one matcher duplicated 3 times under PostToolUse.
  cat > "$cfg" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "/bin/sh"}]},
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "/bin/sh"}]},
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "/bin/sh"}]}
    ]
  }
}
EOF
  local out_dup
  out_dup=$("$HATS_SCRIPT" doctor 2>/dev/null || true)

  # Unique matchers → no dup warning.
  cat > "$cfg" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "/bin/sh"}]}
    ]
  }
}
EOF
  local out_unique
  out_unique=$("$HATS_SCRIPT" doctor 2>/dev/null || true)

  echo '{}' > "$cfg"

  local rc_dup=1 rc_unique=1
  echo "$out_dup"    | grep -q "WARN duplicate hook registration: event=PostToolUse matcher=Bash count=3" && rc_dup=0
  echo "$out_unique" | grep -q "OK   no duplicate hook registrations" && rc_unique=0

  if [ "$rc_dup" -eq 0 ] && [ "$rc_unique" -eq 0 ]; then
    ok "doctor detects duplicate hook registrations"
  else
    die "hook-duplicate check broken (dup_rc=$rc_dup unique_rc=$rc_unique)"
  fi
}

test_completion_scripts() {
  local bash_out zsh_out
  bash_out=$("$HATS_SCRIPT" completion bash)
  zsh_out=$("$HATS_SCRIPT" completion zsh)

  # Bash script must register _hats_completion via complete -F.
  echo "$bash_out" | grep -q 'complete -F _hats_completion hats' \
    || { die "bash completion missing 'complete -F' registration"; return; }
  # And include subcommands list.
  echo "$bash_out" | grep -q 'init add remove' \
    || { die "bash completion missing subcommand list"; return; }

  # Zsh script must register via compdef.
  echo "$zsh_out" | grep -q 'compdef _hats hats' \
    || { die "zsh completion missing 'compdef' registration"; return; }
  echo "$zsh_out" | grep -q "'doctor:Read-only health check'" \
    || { die "zsh completion missing subcommand descriptions"; return; }

  # Sourcing + simulating a bash completion should produce expected matches.
  local result
  result=$(bash -c '
    set +euo pipefail
    source <('"$HATS_SCRIPT"' completion bash)
    COMP_WORDS=(hats d)
    COMP_CWORD=1
    _hats_completion >/dev/null 2>&1 || true
    echo "${COMPREPLY[@]}"
  ')
  case "$result" in
    *default*doctor*|*doctor*default*)
      ok "tab completion for 'hats d' includes default + doctor"
      ;;
    *)
      die "tab completion did not match expected subcommands (got: $result)"
      ;;
  esac
}

test_config_migration_is_idempotent() {
  # Plant a legacy `default` key, run hats, verify it migrates to default_claude.
  cat > "$HATS_DIR/config.toml" <<'EOF'
[hats]
version = "1.1.0"
default_provider = "claude"
default = "foo"
EOF

  "$HATS_SCRIPT" version >/dev/null 2>&1
  local migrated=0
  grep -q '^default_claude[[:space:]]*=[[:space:]]*"foo"' "$HATS_DIR/config.toml" && migrated=1
  grep -qE '^default[[:space:]]*=' "$HATS_DIR/config.toml" && migrated=0

  if [ "$migrated" -eq 1 ]; then
    ok "legacy default key migrates to default_claude"
  else
    die "legacy default key migration did not fire or left legacy line"
  fi

  # Run again; must be no-op.
  local before_sha; before_sha=$(sha1sum "$HATS_DIR/config.toml" | awk '{print $1}')
  "$HATS_SCRIPT" version >/dev/null 2>&1
  local after_sha;  after_sha=$(sha1sum "$HATS_DIR/config.toml" | awk '{print $1}')
  if [ "$before_sha" = "$after_sha" ]; then
    ok "migration is idempotent on second invocation"
  else
    die "migration changed config.toml on idempotent re-run"
  fi
}

# ── Run ───────────────────────────────────────────────────────────

say "HOME=$HOME"
say "HATS_DIR=$HATS_DIR"
test_version
test_help
test_init_creates_layout
test_list_empty_does_not_crash
test_fixture_account_and_default
test_fix_on_fresh_sandbox
test_doctor_runs_after_fixture
test_doctor_catches_invalid_json
test_doctor_catches_missing_hook_command
test_doctor_catches_duplicate_hooks
test_completion_scripts
test_config_migration_is_idempotent

say "summary: $pass pass, $fail fail"
[ "$fail" -eq 0 ]
