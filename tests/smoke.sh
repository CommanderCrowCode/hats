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
test_config_migration_is_idempotent

say "summary: $pass pass, $fail fail"
[ "$fail" -eq 0 ]
