# Test Suite Plan for hats CLI

## Context

hats has zero tests. v0.2.2 shipped three bug fixes (save-back corruption, profile contamination, duplicate account warning). This test suite prevents regressions and validates all 14 commands + helper functions without hitting real APIs.

## Framework

**BATS-core** (Bash Automated Testing System) — vendored as git submodules. No system-wide install needed.

## Mock Strategy

The only external dependency that hits the network is `claude` (called inside `cmd_swap`). Everything else is local file I/O + python3 JSON parsing.

**Mock `claude`** — a configurable bash stub controlled by env vars:
- `MOCK_CLAUDE_EXIT_CODE` — simulate clean exit (0), auth failure (1), SIGINT (130)
- `MOCK_CLAUDE_MODIFY_CREDS` — simulate token refresh (rewrites credentials with new token)
- `MOCK_CLAUDE_MODIFY_STATE` — simulate identity fetch (writes oauthAccount to state file)
- `MOCK_CLAUDE_CLEAR_CREDS` — simulate cred deletion on auth failure
- `MOCK_CLAUDE_LOG_ARGS` — verify argument passthrough

Installed to `$MOCK_BIN/claude` (prepended to PATH) per test. Real `python3` and `flock` are used directly since they're local-only.

## Test Isolation

Every test gets a clean temp directory via `HATS_CLAUDE_DIR` and `HATS_CONFIG_DIR` env vars (already supported by hats). Setup/teardown creates and destroys temp dirs. No real user data is touched.

## File Structure

```
test/
  libs/
    bats-core/          # git submodule
    bats-support/       # git submodule
    bats-assert/        # git submodule
    bats-file/          # git submodule
  helpers/
    setup.bash          # common_setup/teardown, fixture builders, mock installer
    mock_claude.bash    # configurable mock claude script
  test_helpers.bats           # Tier 1: helper functions via CLI (21 tests)
  test_commands_basic.bats    # Tier 2: add, remove, list, default, etc. (38 tests)
  test_swap.bats              # Tier 3: swap lifecycle (19 tests)
  test_vault.bats             # Tier 4: backup/restore/stash/unstash/fix (24 tests)
  test_regressions.bats       # Tier 5: v0.2.x bug regressions (16 tests)
  test_edge_cases.bats        # Tier 6: error handling, edge cases (15 tests)
run_tests.sh                  # convenience runner
```

## Test Tiers (~133 tests total, estimated <10s runtime)

### Tier 1: Helper Functions (21 tests) — `test_helpers.bats`

Tested indirectly via CLI output (can't source hats directly due to `{ }` guard).

- **Path generation** (`_creds_file`, `_profile_file`) — verified via `hats add` output files
- **Account scanning** (`_accounts`) — empty dir, single, multiple, non-matching files ignored
- **Default resolution** (`_default_account`) — config file, fallback to first, empty
- **Token parsing** (`_token_info` via `hats list`) — valid, expired+refresh, expired-no-refresh, scopes, malformed JSON, missing keys
- **Profile save/restore** — state file present/absent, oauthAccount present/absent
- **flock detection** — present vs missing
- **Status display** — default marker, vault marker, missing creds

### Tier 2: Local Commands (38 tests) — `test_commands_basic.bats`

- `init` — creates dirs, detects accounts, sets default
- `add` — validation (no name, exists, no creds), copies file, permissions, profile, default setting
- `remove` — validation, deletes files, warns on default, preserves vault
- `list` — no accounts, header, status, lock states
- `default` — get/set, validation
- `shell-init` — generates functions, `--skip-permissions` flag
- `version`/`help` — output, aliases (`-v`, `-h`, `--version`, `--help`)
- Unknown command — error message, exit 1
- Aliases — `rm`, `ls`, `status`

### Tier 3: Swap Command (19 tests) — `test_swap.bats`

All use mock claude. The most complex command.

- **Argument handling** — missing name, bad account, missing default creds
- **Credential lifecycle** — creds swapped before claude, restored after, token refresh saved back
- **Profile lifecycle** — target profile restored before claude, saved after clean exit, default restored after
- **Exit code propagation** — rc=0, rc=1, rc=130
- **Argument passthrough** — args forwarded, `--` stripped, special chars preserved
- **Env var cleanup** — `CLAUDE_CODE_OAUTH_TOKEN` unset
- **File locking** — lock file used during swap

### Tier 4: Vault & Stash (24 tests) — `test_vault.bats`

- `backup` — creates vault, copies creds+profiles, permissions, count
- `restore` (all) — restores all, profiles, sets active to default, count
- `restore <name>` — single account, missing vault entry, active creds set
- `stash` — moves active to .stash, active removed, no-creds case
- `unstash` — moves back, permissions, no-stash error, stash removed
- `fix` — creates dirs, sets default, copies creds, restores profile, clears lock, stash warning

### Tier 5: Regression Tests (16 tests) — `test_regressions.bats`

**Highest priority. Directly targets v0.2.x bugs.**

- **Save-back default corruption (v0.2.2):** swap to default skips restore, refresh still saved, non-default restore works, no stale overwrite
- **Profile contamination (v0.2.2):** failed exit skips profile save, clean exit saves profile, wrong identity on failure not persisted, correct identity on success persisted
- **Duplicate email warning (v0.2.2):** same email warns, different email no warning, warning text includes names+email, graceful when no profile exists
- **Pre-swap profile protection (v0.2.1):** default profile not overwritten before swap
- **Stale identity cleared (v0.2.1):** no profile = oauthAccount cleared, has profile = oauthAccount set

### Tier 6: Edge Cases (15 tests) — `test_edge_cases.bats`

- Missing dirs — CLAUDE_DIR, CONFIG_DIR
- Account naming — hyphens, underscores, dots
- Concurrency — sequential swaps, stale lock fix
- State file — missing, no oauthAccount, other keys preserved
- Corrupt data — empty creds, non-JSON creds, creds deleted mid-session
- Stress — 10 accounts listed, 10 accounts shell-init

## Implementation Order

1. BATS submodules + `run_tests.sh`
2. `test/helpers/setup.bash` (shared infrastructure)
3. `test/helpers/mock_claude.bash`
4. `test_regressions.bats` (highest value — prevents re-introducing the bugs we just fixed)
5. `test_swap.bats` (most complex command)
6. `test_commands_basic.bats`
7. `test_helpers.bats`
8. `test_vault.bats`
9. `test_edge_cases.bats`

## Setup Commands

```bash
# From the project root
mkdir -p test/libs test/helpers

# Add BATS as git submodules
git submodule add https://github.com/bats-core/bats-core.git test/libs/bats-core
git submodule add https://github.com/bats-core/bats-support.git test/libs/bats-support
git submodule add https://github.com/bats-core/bats-assert.git test/libs/bats-assert
git submodule add https://github.com/bats-core/bats-file.git test/libs/bats-file
```

## Running Tests

```bash
./run_tests.sh                            # All tests
./run_tests.sh test/test_regressions.bats  # Just regression tests
./run_tests.sh test/test_swap.bats         # Just swap tests
```

All 133 tests should pass, run in <10 seconds, and never contact any external API.
