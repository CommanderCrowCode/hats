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
HATS_REPO="$(dirname "$HATS_SCRIPT")"
[ -x "$HATS_SCRIPT" ] || { echo "missing or non-executable hats at $HATS_SCRIPT" >&2; exit 1; }
[ -x "$HATS_REPO/install.sh" ] || { echo "missing or non-executable install.sh at $HATS_REPO/install.sh" >&2; exit 1; }

# Sandbox both HOME and HATS_DIR so the suite never touches the user's real
# `~/.claude` / `~/.codex` runtime symlinks. hats resolves $HOME/.claude
# dynamically (via `$HOME/.claude` in `_configure_provider`), so overriding HOME
# is the cleanest way to isolate. The real shell env is unaffected — these are
# only exported in this subshell.
SANDBOX_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hats-smoke-XXXXXX")"
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

test_fix_dedupes_duplicate_hooks() {
  local base="$HATS_DIR/claude/base"
  local cfg="$base/settings.json"
  mkdir -p "$base"

  # Seed the same matcher 3x under PostToolUse and 2x under Stop (no matcher),
  # plus one unique entry that must survive verbatim.
  cat > "$cfg" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "/bin/sh"}]},
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "/bin/sh"}]},
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "/bin/sh"}]},
      {"matcher": "Edit", "hooks": [{"type": "command", "command": "/bin/true"}]}
    ],
    "Stop": [
      {"hooks": [{"type": "command", "command": "/bin/stop"}]},
      {"hooks": [{"type": "command", "command": "/bin/stop"}]}
    ]
  }
}
EOF

  local out_fix
  out_fix=$("$HATS_SCRIPT" fix 2>/dev/null || true)

  local out_doctor
  out_doctor=$("$HATS_SCRIPT" doctor 2>/dev/null || true)

  # Content checks: fix must report removal counts; doctor must now be clean;
  # the unique Edit entry and exactly one Bash entry must remain.
  local rc_fix_bash=1 rc_fix_stop=1 rc_doctor=1 rc_kept_edit=1 rc_bash_count=1
  echo "$out_fix"    | grep -q "deduped base/settings.json hooks: event=PostToolUse matcher=Bash removed=2" && rc_fix_bash=0
  echo "$out_fix"    | grep -q "deduped base/settings.json hooks: event=Stop matcher=(no-matcher) removed=1" && rc_fix_stop=0
  echo "$out_doctor" | grep -q "no duplicate hook registrations" && rc_doctor=0

  if command -v python3 >/dev/null 2>&1; then
    local bash_count edit_count
    bash_count=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(sum(1 for i in d["hooks"]["PostToolUse"] if i.get("matcher")=="Bash"))' "$cfg")
    edit_count=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(sum(1 for i in d["hooks"]["PostToolUse"] if i.get("matcher")=="Edit"))' "$cfg")
    [ "$bash_count" = "1" ] && rc_bash_count=0
    [ "$edit_count" = "1" ] && rc_kept_edit=0
  else
    rc_bash_count=0
    rc_kept_edit=0
  fi

  echo '{}' > "$cfg"

  if [ "$rc_fix_bash" -eq 0 ] && [ "$rc_fix_stop" -eq 0 ] \
     && [ "$rc_doctor" -eq 0 ] && [ "$rc_bash_count" -eq 0 ] && [ "$rc_kept_edit" -eq 0 ]; then
    ok "fix dedupes duplicate hook registrations in base/settings.json"
  else
    die "fix dedupe broken (fix_bash=$rc_fix_bash fix_stop=$rc_fix_stop doctor=$rc_doctor bash_count=$rc_bash_count kept_edit=$rc_kept_edit)"
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

  # Sourcing + live simulation needs a recent bash + bash-completion; skip if
  # either is missing (macOS GH runner ships bash 3.2 at /bin/bash with no
  # bash-completion). The static-content checks above are what matter.
  ok "completion scripts emit expected content for bash + zsh"
}

test_doctor_flags_suspicious_symlink() {
  # Plant a symlink in base/ pointing outside $HOME — doctor must WARN.
  local base="$HATS_DIR/claude/base"
  mkdir -p "$base"

  # Create a target outside HOME in a directory we can read.
  local outside
  outside=$(mktemp "${TMPDIR:-/tmp}/hats-outside-XXXXXX")
  ln -sfn "$outside" "$base/sneaky_link"

  local out rc=0
  # Capture rc in the current shell — `rc=$?` inside `$()` is a subshell
  # modification and is lost (SC2030/SC2031).
  out=$("$HATS_SCRIPT" doctor 2>&1) || rc=$?

  rm -f "$base/sneaky_link" "$outside"

  if echo "$out" | grep -q 'WARN base/sneaky_link symlink resolves outside'; then
    ok "doctor flags base symlinks pointing outside \$HOME"
  else
    die "doctor did not warn on out-of-HOME symlink (rc=$rc out=$out)"
  fi
}

test_no_color_flag() {
  # --no-color must suppress ANSI escapes even if a future default flips on.
  # When stdout is a pipe (as here), colors are already auto-disabled — but
  # --no-color must ALSO disable them if TTY detection is ever overridden.
  local out
  out=$("$HATS_SCRIPT" --no-color doctor 2>&1 || true)
  if printf '%s' "$out" | grep -q $'\033\[[0-9]*m'; then
    die "ANSI escape codes leaked through --no-color"
  else
    ok "--no-color suppresses ANSI escapes"
  fi
}

test_link_unlink_resource_validation() {
  # Regression for the security audit medium #4 finding: `hats link/unlink`
  # must reject path-traversal, globs, and dot entries.
  local acct="$HATS_DIR/claude/foo"
  [ -d "$acct" ] || { mkdir -p "$acct"; : > "$acct/.credentials.json"; chmod 600 "$acct/.credentials.json"; echo '{}' > "$acct/.claude.json"; }

  # Capture output separately — hats exits non-zero on die, and `set -o
  # pipefail` would mask the grep success if we piped directly.
  local rejects=0 out
  for bad in '../etc/shadow' '*' '..' '.' 'foo/bar' '?x'; do
    out=$("$HATS_SCRIPT" link foo "$bad" 2>&1 || true)
    if echo "$out" | grep -q 'Invalid resource name'; then
      rejects=$((rejects + 1))
    fi
  done
  if [ "$rejects" -eq 6 ]; then
    ok "link/unlink rejects path-traversal, globs, and dot entries"
  else
    die "resource-name validator let something through ($rejects/6 rejections)"
  fi
}

test_install_help_exits_zero() {
  local out rc=0
  out=$("$HATS_REPO/install.sh" --help 2>&1) || rc=$?
  if [ "$rc" -eq 0 ] && echo "$out" | grep -q "Install hats to"; then
    ok "install.sh --help exits 0 with help text"
  else
    die "install.sh --help broken (rc=$rc)"
  fi
}

test_install_rejects_unknown_flag() {
  local rc=0
  "$HATS_REPO/install.sh" --bogus >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 2 ]; then
    ok "install.sh rejects unknown flag with exit 2"
  else
    die "install.sh unknown-flag rejection broken (rc=$rc, want 2)"
  fi
}

test_install_rejects_too_many_args() {
  local rc=0
  "$HATS_REPO/install.sh" /tmp/a /tmp/b >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 2 ]; then
    ok "install.sh rejects >1 positional arg with exit 2"
  else
    die "install.sh too-many-args rejection broken (rc=$rc, want 2)"
  fi
}

test_install_to_sandbox_stamps_commit() {
  # Installs hats into a throwaway dir and verifies the atomic-install
  # succeeds + the COMMIT line was rewritten from "dev" to a real short
  # sha (or "unknown" if git is unavailable). Also confirms the resulting
  # binary is executable and runnable.
  local dest
  dest=$(mktemp -d "${TMPDIR:-/tmp}/hats-install-XXXXXX")

  local rc=0
  "$HATS_REPO/install.sh" "$dest" >/dev/null 2>&1 || rc=$?

  local installed="$dest/hats"
  local have_bin=0 have_exec=0 have_commit=0 have_no_tmp=1 runs_ok=0
  [ -f "$installed" ] && have_bin=1
  [ -x "$installed" ] && have_exec=1
  if [ "$have_bin" -eq 1 ]; then
    if grep -qE '^COMMIT="([0-9a-f]+|unknown)"$' "$installed" \
       && ! grep -q '^COMMIT="dev"$' "$installed"; then
      have_commit=1
    fi
    # Atomic install must not leave temp/bak residue behind. `compgen -G`
    # is bash-native and returns 0 iff any file matches the glob — safer
    # than `ls | grep` (SC2010).
    if compgen -G "$dest/hats.tmp.*" >/dev/null; then
      have_no_tmp=0
    fi
    "$installed" version >/dev/null 2>&1 && runs_ok=1
  fi

  rm -rf "$dest"

  if [ "$rc" -eq 0 ] && [ "$have_bin" -eq 1 ] && [ "$have_exec" -eq 1 ] \
     && [ "$have_commit" -eq 1 ] && [ "$have_no_tmp" -eq 1 ] && [ "$runs_ok" -eq 1 ]; then
    ok "install.sh installs hats atomically and stamps COMMIT"
  else
    die "install.sh install broken (rc=$rc bin=$have_bin exec=$have_exec commit=$have_commit no_tmp=$have_no_tmp runs=$runs_ok)"
  fi
}

test_rejection_paths_exit_nonzero() {
  # Three small rejection paths that must remain non-zero — regression against
  # any future refactor that prints "Error:" but forgets to `die` / exit 1.
  #
  # (a) `hats add <name> --api-key` on the claude provider — the flag is
  #     codex-only and cmd_add dies explicitly.
  # (b) `hats default <missing>` — account not found.
  # (c) `hats status <missing>` — account not found.
  local rc_a=0 rc_b=0 rc_c=0
  "$HATS_SCRIPT" add probe --api-key        >/dev/null 2>&1 || rc_a=$?
  "$HATS_SCRIPT" default nosuchaccount      >/dev/null 2>&1 || rc_b=$?
  "$HATS_SCRIPT" status  nosuchaccount      >/dev/null 2>&1 || rc_c=$?

  if [ "$rc_a" -ne 0 ] && [ "$rc_b" -ne 0 ] && [ "$rc_c" -ne 0 ]; then
    ok "add/default/status reject invalid input with non-zero rc"
  else
    die "rejection paths leak rc=0 (add=$rc_a default=$rc_b status=$rc_c)"
  fi
}

test_doctor_flags_missing_auth_and_broken_symlink() {
  # Covers doctor §4a (missing $PRIMARY_AUTH_FILE) and §4b (broken symlink
  # under the account dir). Previously only the base-level doctor checks
  # (§2b/§2d/§2e/§2f) had coverage. These two detections are what catch the
  # "user half-deleted their ~/.credentials.json" and "user pointed a symlink
  # at a path that no longer exists" scenarios — both real regression targets.
  local acct="$HATS_DIR/claude/docbroken"
  mkdir -p "$acct"
  # §4a: no .credentials.json on disk
  # §4b: symlink to a path that does not exist
  ln -s /nonexistent/target "$acct/dangling"

  local out rc=0
  out=$("$HATS_SCRIPT" doctor 2>&1) || rc=$?

  rm -rf "$acct"

  local missing_ok=0 broken_ok=0
  echo "$out" | grep -q "FAIL .credentials.json missing" && missing_ok=1
  echo "$out" | grep -q "FAIL broken symlink: dangling"  && broken_ok=1

  # Doctor must exit non-zero because both are FAIL (not WARN).
  local nonzero_ok=0
  [ "$rc" -ne 0 ] && nonzero_ok=1

  if [ "$missing_ok" -eq 1 ] && [ "$broken_ok" -eq 1 ] && [ "$nonzero_ok" -eq 1 ]; then
    ok "doctor flags per-account missing auth file + broken symlink with non-zero exit"
  else
    die "doctor per-account checks broken (missing=$missing_ok broken=$broken_ok rc_nonzero=$nonzero_ok)"
  fi
}

test_swap_error_paths() {
  # `hats swap <missing>` and `hats swap <account-with-no-credentials>` are
  # the only swap paths reachable without a real `claude` binary. Both must
  # exit non-zero with specific error text so CI pipelines can detect
  # failure — the regression concern is a silent rc=0 after an Error: line
  # (would be invisible to `set -e` callers).
  local acct="$HATS_DIR/claude/nocred"
  mkdir -p "$acct"
  # NOTE: no .credentials.json

  local out_missing rc_missing=0
  out_missing=$("$HATS_SCRIPT" swap does-not-exist 2>&1) || rc_missing=$?

  local out_nocred rc_nocred=0
  out_nocred=$("$HATS_SCRIPT" swap nocred 2>&1) || rc_nocred=$?

  rm -rf "$acct"

  local missing_ok=0 nocred_ok=0
  [ "$rc_missing" -ne 0 ] && echo "$out_missing" | grep -q "not found" && missing_ok=1
  [ "$rc_nocred"  -ne 0 ] && echo "$out_nocred"  | grep -q "no credentials" && nocred_ok=1

  if [ "$missing_ok" -eq 1 ] && [ "$nocred_ok" -eq 1 ]; then
    ok "swap rejects missing + no-credentials accounts with non-zero rc"
  else
    die "swap error paths broken (missing=$missing_ok/rc=$rc_missing nocred=$nocred_ok/rc=$rc_nocred)"
  fi
}

test_command_aliases() {
  # Aliases `ls`, `rm`, `mv` for list / remove / rename — listed in help + the
  # completion scripts but previously untested. Verifies the main-dispatch
  # case statement routes them identically.
  local acct="$HATS_DIR/claude/aliastest"
  mkdir -p "$acct"
  : > "$acct/.credentials.json"
  chmod 600 "$acct/.credentials.json"
  echo '{}' > "$acct/.claude.json"

  # ls: equivalent to list
  local ls_out; ls_out=$("$HATS_SCRIPT" ls 2>&1)
  local ls_ok=0
  echo "$ls_out" | grep -q "hats v.* — Claude Code Accounts" \
    && echo "$ls_out" | grep -q "aliastest" && ls_ok=1

  # mv: equivalent to rename
  local rc_mv=0
  "$HATS_SCRIPT" mv aliastest aliastest2 >/dev/null 2>&1 || rc_mv=$?
  local mv_ok=0
  [ "$rc_mv" -eq 0 ] && [ -d "$HATS_DIR/claude/aliastest2" ] \
    && [ ! -d "$HATS_DIR/claude/aliastest" ] && mv_ok=1

  # rm: equivalent to remove
  local rc_rm=0
  "$HATS_SCRIPT" rm aliastest2 >/dev/null 2>&1 || rc_rm=$?
  local rm_ok=0
  [ "$rc_rm" -eq 0 ] && [ ! -d "$HATS_DIR/claude/aliastest2" ] && rm_ok=1

  if [ "$ls_ok" -eq 1 ] && [ "$mv_ok" -eq 1 ] && [ "$rm_ok" -eq 1 ]; then
    ok "command aliases ls/mv/rm route to list/rename/remove"
  else
    die "aliases broken (ls=$ls_ok mv=$mv_ok rm=$rm_ok)"
  fi
}

test_link_unlink_happy_path() {
  # Happy path for cmd_link / cmd_unlink — complementary to
  # test_link_unlink_resource_validation which only covers the rejection paths.
  # - link creates a symlink `<acct>/<res> -> ../base/<res>`
  # - unlink removes the symlink and copies the base content into the account
  #   dir so the account owns an isolated copy
  local base="$HATS_DIR/claude/base"
  local acct="$HATS_DIR/claude/foo"
  local resource="scratchpad"
  local base_file="$base/$resource"
  local acct_file="$acct/$resource"

  # Seed base with a content file that's not already hard-linked into foo.
  echo "hello from base" > "$base_file"

  # link: symlink points to ../base/<resource>
  local rc_link=0
  "$HATS_SCRIPT" link foo "$resource" >/dev/null 2>&1 || rc_link=$?
  local is_symlink=0 target_ok=0
  if [ -L "$acct_file" ]; then
    is_symlink=1
    [ "$(readlink "$acct_file")" = "../base/$resource" ] && target_ok=1
  fi

  # link again must fail — "already linked"
  local rc_relink=0
  "$HATS_SCRIPT" link foo "$resource" >/dev/null 2>&1 || rc_relink=$?

  # unlink: replaces the symlink with a copy of base content
  local rc_unlink=0
  "$HATS_SCRIPT" unlink foo "$resource" >/dev/null 2>&1 || rc_unlink=$?
  local is_file=0 content_ok=0
  if [ -f "$acct_file" ] && [ ! -L "$acct_file" ]; then
    is_file=1
    [ "$(cat "$acct_file")" = "hello from base" ] && content_ok=1
  fi

  # unlink again must fail — "already isolated"
  local rc_reunlink=0
  "$HATS_SCRIPT" unlink foo "$resource" >/dev/null 2>&1 || rc_reunlink=$?

  # Cleanup leaves base seeded for downstream tests — remove the fixture we added.
  rm -f "$base_file" "$acct_file"

  if [ "$rc_link" -eq 0 ] && [ "$is_symlink" -eq 1 ] && [ "$target_ok" -eq 1 ] \
     && [ "$rc_relink" -ne 0 ] && [ "$rc_unlink" -eq 0 ] && [ "$is_file" -eq 1 ] \
     && [ "$content_ok" -eq 1 ] && [ "$rc_reunlink" -ne 0 ]; then
    ok "link/unlink happy path — symlink created, content materialized on unlink, re-ops reject"
  else
    die "link/unlink broken (rc_link=$rc_link sym=$is_symlink tgt=$target_ok rc_relink=$rc_relink rc_unlink=$rc_unlink file=$is_file content=$content_ok rc_reunlink=$rc_reunlink)"
  fi
}

test_providers_and_default_getter() {
  # `hats providers` lists the supported providers and marks the current
  # default. `hats default` with no arg prints the current default. Both are
  # small surface commands with zero prior coverage.
  local prov_out def_out
  prov_out=$("$HATS_SCRIPT" providers 2>&1)
  def_out=$("$HATS_SCRIPT" default 2>&1)

  local prov_ok=0 def_ok=0
  echo "$prov_out" | grep -q "claude" \
    && echo "$prov_out" | grep -q "codex" \
    && echo "$prov_out" | grep -q "Default provider:" \
    && prov_ok=1
  echo "$def_out" | grep -q "Default account: foo" && def_ok=1

  if [ "$prov_ok" -eq 1 ] && [ "$def_ok" -eq 1 ]; then
    ok "providers + default-getter surfaces print expected content"
  else
    die "providers/default getter broken (providers=$prov_ok default=$def_ok)"
  fi
}

test_shell_init_emits_functions_per_account() {
  # `hats shell-init` is the primary user integration — emits shell functions
  # so typing the account name runs the provider with that account's config
  # dir. Zero prior coverage. After the fixture + CRUD tests run, `foo` is
  # the only remaining claude account.
  local out
  out=$("$HATS_SCRIPT" shell-init 2>&1)
  local has_header=0 has_foo_fn=0 has_env_var=0
  echo "$out" | grep -q "Generated by hats shell-init for claude" && has_header=1
  # Claude shim: `foo() { CLAUDE_CONFIG_DIR="..." claude "$@"; }`
  echo "$out" | grep -qE '^foo\(\).*CLAUDE_CONFIG_DIR=.*claude/foo.*claude.*"\$@"' && has_foo_fn=1
  echo "$out" | grep -q 'CLAUDE_CONFIG_DIR=' && has_env_var=1

  # --skip-permissions injects `--dangerously-skip-permissions` for claude
  local out_skip
  out_skip=$("$HATS_SCRIPT" shell-init --skip-permissions 2>&1)
  local has_skip_flag=0
  echo "$out_skip" | grep -q -- '--dangerously-skip-permissions' && has_skip_flag=1

  # Stage a codex account directly (codex/base was created by the codex
  # provider routing test earlier in the run) so shell-init emits a shim.
  local codex_acct="$HATS_DIR/codex/cx1"
  mkdir -p "$codex_acct"
  : > "$codex_acct/auth.json"
  chmod 600 "$codex_acct/auth.json"

  # Codex shim must use CODEX_HOME and wrap codex with -c cli_auth_credentials_store
  local out_codex
  out_codex=$("$HATS_SCRIPT" codex shell-init 2>&1)
  local has_codex_env=0 has_codex_fn=0
  echo "$out_codex" | grep -q 'CODEX_HOME=.*codex/cx1' && has_codex_env=1
  echo "$out_codex" | grep -qE '^codex_cx1\(\)' && has_codex_fn=1

  # codex shell-init must reject --skip-permissions (claude-only)
  local rc_codex_skip=0
  "$HATS_SCRIPT" codex shell-init --skip-permissions >/dev/null 2>&1 || rc_codex_skip=$?

  rm -rf "$codex_acct"

  if [ "$has_header" -eq 1 ] && [ "$has_foo_fn" -eq 1 ] && [ "$has_env_var" -eq 1 ] \
     && [ "$has_skip_flag" -eq 1 ] && [ "$has_codex_env" -eq 1 ] && [ "$has_codex_fn" -eq 1 ] \
     && [ "$rc_codex_skip" -ne 0 ]; then
    ok "shell-init emits per-account shims (claude+codex, codex_<name> prefix) and rejects codex --skip-permissions"
  else
    die "shell-init broken (header=$has_header foo=$has_foo_fn env=$has_env_var skip=$has_skip_flag codex=$has_codex_env codex_fn=$has_codex_fn codex_skip_rc=$rc_codex_skip)"
  fi
}

test_account_crud_roundtrip() {
  # Walks through list → rename → status → remove using a second fixture
  # account (alongside the `foo` already staged by test_fixture_account_and_default).
  # No tests currently exercise cmd_remove / cmd_rename / cmd_status, so this is
  # the first coverage for the account-lifecycle CRUD surface.
  local acct="$HATS_DIR/claude/bar"
  mkdir -p "$acct"
  : > "$acct/.credentials.json"
  chmod 600 "$acct/.credentials.json"
  echo '{}' > "$acct/.claude.json"

  local list_out; list_out=$("$HATS_SCRIPT" list 2>&1)
  local list_ok=0
  echo "$list_out" | grep -q "foo" && echo "$list_out" | grep -q "bar" \
    && echo "$list_out" | grep -q "2 account" && list_ok=1

  # rename bar → baz
  local rename_out rc_rename=0
  rename_out=$("$HATS_SCRIPT" rename bar baz 2>&1) || rc_rename=$?
  local rename_ok=0
  [ "$rc_rename" -eq 0 ] && [ -d "$HATS_DIR/claude/baz" ] && [ ! -d "$HATS_DIR/claude/bar" ] \
    && echo "$rename_out" | grep -q "renamed to 'baz'" && rename_ok=1

  # status baz must print Provider/Account/Directory headers
  local status_out; status_out=$("$HATS_SCRIPT" status baz 2>&1)
  local status_ok=0
  echo "$status_out" | grep -q "Provider: claude" \
    && echo "$status_out" | grep -q "Account: baz" \
    && echo "$status_out" | grep -q "Directory: .*claude/baz" \
    && status_ok=1

  # rename validates: rejects unknown source, rejects existing target
  local rc_unknown=0 rc_collision=0
  "$HATS_SCRIPT" rename nope also-nope >/dev/null 2>&1 || rc_unknown=$?
  "$HATS_SCRIPT" rename baz foo       >/dev/null 2>&1 || rc_collision=$?
  local rename_validate_ok=0
  [ "$rc_unknown" -ne 0 ] && [ "$rc_collision" -ne 0 ] && rename_validate_ok=1

  # remove baz
  local rc_remove=0
  "$HATS_SCRIPT" remove baz >/dev/null 2>&1 || rc_remove=$?
  local remove_ok=0
  [ "$rc_remove" -eq 0 ] && [ ! -d "$HATS_DIR/claude/baz" ] && remove_ok=1

  # remove on nonexistent must fail
  local rc_remove_missing=0
  "$HATS_SCRIPT" remove baz >/dev/null 2>&1 || rc_remove_missing=$?
  local remove_missing_ok=0
  [ "$rc_remove_missing" -ne 0 ] && remove_missing_ok=1

  if [ "$list_ok" -eq 1 ] && [ "$rename_ok" -eq 1 ] && [ "$status_ok" -eq 1 ] \
     && [ "$rename_validate_ok" -eq 1 ] && [ "$remove_ok" -eq 1 ] && [ "$remove_missing_ok" -eq 1 ]; then
    ok "account CRUD roundtrip (list/rename/status/remove) enforces validation"
  else
    die "CRUD roundtrip broken (list=$list_ok rename=$rename_ok status=$status_ok validate=$rename_validate_ok remove=$remove_ok remove_missing=$remove_missing_ok)"
  fi
}

test_codex_provider_routing() {
  # `hats codex <cmd>` dispatches to the codex provider: a separate ~/.hats/codex
  # tree, a "Codex Accounts" list header, and completion that still works.
  # None of these require the `codex` binary to be installed.
  local rc_init=0 rc_list=0
  local list_out=""
  local have_codex_base=0 have_claude_untouched=1

  "$HATS_SCRIPT" codex init >/dev/null 2>&1 || rc_init=$?
  [ -d "$HATS_DIR/codex/base" ] && have_codex_base=1
  # Initializing codex must not disturb the existing claude tree — accounts
  # from earlier tests (foo fixture) must still be there.
  [ -d "$HATS_DIR/claude/foo" ] || have_claude_untouched=0

  list_out=$("$HATS_SCRIPT" codex list 2>&1) || rc_list=$?

  local header_ok=0 no_accts_ok=0
  echo "$list_out" | grep -q "hats v.* — Codex Accounts" && header_ok=1
  echo "$list_out" | grep -q "No accounts found" && no_accts_ok=1

  if [ "$rc_init" -eq 0 ] && [ "$have_codex_base" -eq 1 ] && [ "$have_claude_untouched" -eq 1 ] \
     && [ "$rc_list" -eq 0 ] && [ "$header_ok" -eq 1 ] && [ "$no_accts_ok" -eq 1 ]; then
    ok "hats codex init + list route to codex/ tree without disturbing claude/"
  else
    die "codex provider routing broken (rc_init=$rc_init codex_base=$have_codex_base claude_ok=$have_claude_untouched rc_list=$rc_list header=$header_ok no_accts=$no_accts_ok)"
  fi
}

test_codex_completion_emits_script() {
  # `hats codex completion bash|zsh` must emit the same provider-agnostic
  # completion script (which internally supports both `hats <cmd>` and
  # `hats codex <cmd>` via providers-list parsing).
  local bash_out zsh_out
  bash_out=$("$HATS_SCRIPT" codex completion bash 2>/dev/null)
  zsh_out=$("$HATS_SCRIPT" codex completion zsh 2>/dev/null)

  local bash_ok=0 zsh_ok=0
  echo "$bash_out" | grep -q "^_hats_completion()" \
    && echo "$bash_out" | grep -q 'providers=.*codex' \
    && bash_ok=1
  echo "$zsh_out"  | grep -q "^_hats()" \
    && echo "$zsh_out"  | grep -q 'providers=.*codex' \
    && zsh_ok=1

  if [ "$bash_ok" -eq 1 ] && [ "$zsh_ok" -eq 1 ]; then
    ok "hats codex completion emits bash+zsh scripts covering both providers"
  else
    die "codex completion broken (bash=$bash_ok zsh=$zsh_ok)"
  fi
}

test_install_check_gates_on_smoke() {
  # `install.sh --check <dir>` must: (1) run the smoke suite, (2) install only
  # on pass, (3) abort with exit 1 on fail. We verify both branches hermetically
  # by staging a fake repo with a stub smoke.sh — otherwise --check would invoke
  # this very file and recurse.
  local stage pass_dest fail_dest rc_pass=0 rc_fail=0 installed_on_pass=0 installed_on_fail=0
  stage=$(mktemp -d "${TMPDIR:-/tmp}/hats-install-check-XXXXXX")
  mkdir -p "$stage/tests"
  cp "$HATS_REPO/install.sh" "$stage/install.sh"
  cp "$HATS_REPO/hats"       "$stage/hats"

  # Passing stub
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stage/tests/smoke.sh"
  chmod +x "$stage/tests/smoke.sh"
  pass_dest=$(mktemp -d "${TMPDIR:-/tmp}/hats-install-check-pass-XXXXXX")
  "$stage/install.sh" --check "$pass_dest" >/dev/null 2>&1 || rc_pass=$?
  [ -x "$pass_dest/hats" ] && installed_on_pass=1

  # Failing stub
  printf '#!/usr/bin/env bash\nexit 1\n' > "$stage/tests/smoke.sh"
  chmod +x "$stage/tests/smoke.sh"
  fail_dest=$(mktemp -d "${TMPDIR:-/tmp}/hats-install-check-fail-XXXXXX")
  "$stage/install.sh" --check "$fail_dest" >/dev/null 2>&1 || rc_fail=$?
  [ -x "$fail_dest/hats" ] && installed_on_fail=1

  rm -rf "$stage" "$pass_dest" "$fail_dest"

  if [ "$rc_pass" -eq 0 ] && [ "$installed_on_pass" -eq 1 ] \
     && [ "$rc_fail" -eq 1 ] && [ "$installed_on_fail" -eq 0 ]; then
    ok "install.sh --check installs on smoke pass, aborts on smoke fail"
  else
    die "install.sh --check gate broken (pass rc=$rc_pass installed=$installed_on_pass / fail rc=$rc_fail installed=$installed_on_fail)"
  fi
}

test_install_is_idempotent_on_reinstall() {
  # Second install over the same target must succeed atomically: no leftover
  # hats.tmp.* files, binary still runs, and the mv -f overwrites the previous
  # copy in place.
  local dest rc1=0 rc2=0 have_no_tmp=1 runs_ok=0
  dest=$(mktemp -d "${TMPDIR:-/tmp}/hats-reinstall-XXXXXX")

  "$HATS_REPO/install.sh" "$dest" >/dev/null 2>&1 || rc1=$?
  "$HATS_REPO/install.sh" "$dest" >/dev/null 2>&1 || rc2=$?

  if compgen -G "$dest/hats.tmp.*" >/dev/null; then
    have_no_tmp=0
  fi
  "$dest/hats" version >/dev/null 2>&1 && runs_ok=1

  rm -rf "$dest"

  if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$have_no_tmp" -eq 1 ] && [ "$runs_ok" -eq 1 ]; then
    ok "install.sh is idempotent on reinstall (no tmp residue, binary still runs)"
  else
    die "install.sh reinstall broken (rc1=$rc1 rc2=$rc2 no_tmp=$have_no_tmp runs=$runs_ok)"
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
  local before_sha; before_sha=$(shasum -a 1 "$HATS_DIR/config.toml" | awk '{print $1}')
  "$HATS_SCRIPT" version >/dev/null 2>&1
  local after_sha;  after_sha=$(shasum -a 1 "$HATS_DIR/config.toml" | awk '{print $1}')
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
test_fix_dedupes_duplicate_hooks
test_completion_scripts
test_doctor_flags_suspicious_symlink
test_no_color_flag
test_link_unlink_resource_validation
test_account_crud_roundtrip
test_codex_provider_routing
test_codex_completion_emits_script
test_rejection_paths_exit_nonzero
test_doctor_flags_missing_auth_and_broken_symlink
test_swap_error_paths
test_command_aliases
test_link_unlink_happy_path
test_providers_and_default_getter
test_shell_init_emits_functions_per_account
test_install_help_exits_zero
test_install_rejects_unknown_flag
test_install_rejects_too_many_args
test_install_to_sandbox_stamps_commit
test_install_check_gates_on_smoke
test_install_is_idempotent_on_reinstall
test_config_migration_is_idempotent

say "summary: $pass pass, $fail fail"
[ "$fail" -eq 0 ]
