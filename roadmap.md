# Roadmap

## Next Items (self-prioritized, hats-lead judgment)

Per praetor directive 2026-04-19: 5-10 items ordered by project-lead judgment, not
operator-FIFO. Pick the next one off this list when current work ships. Minor
re-ordering is at hats-lead's discretion; major pivots (dropping the top 3,
adding a new top-priority) surface via praetor.

Honest framing for hats: the project is in a mature-steady state after
2026-04-17/18's 30+ commit hardening push. Many items below are **days** of
work, not hours, and the top-priority item is blocked on operator crypto
choice. Tanwa explicitly permits single-agent idleness when there's genuinely
nothing left to ship — hats is near that state.

### 1. `hats export` / `hats import` — portable credential transfer  (v1.1 closer)
**Why now:** last unchecked v1.1 item. PRD is complete (`docs/prd-export-import.md`). Linear MSH-11 (Todo). A crypto-agnostic scaffold — argparse parsing, tarball pack/unpack, manifest schema — can land *today* even before operator picks the backend; the crypto plug slots in as a strategy pattern once age/gpg/openssl is chosen.
**Scope:** days (scaffold = hours; full backend wiring = days once unblocked).
**Blocker:** operator crypto choice (age vs gpg vs OS-keychain). Not going to preempt. Scaffold work is unblocked.

### 2. Audit log — timestamped swap / add / remove history  ✅ SHIPPED 2026-04-19
**Status:** landed as opt-in JSONL audit log. Enable via `HATS_AUDIT=1`; reader is `hats audit` with `-n <count>` and `--raw` flags. Events: add / remove / rename / default / swap / link / unlink. Read-only commands (list / doctor / status / help / version) are NOT logged — signal hygiene on shared machines. Tests in `tests/smoke.sh::test_audit_log_opt_in_records_mutations_and_skips_reads`. Threat-model note: SECURITY.md's "No audit logging" gap now has a concrete answer for multi-user dev boxes. Commit: see `git log --grep 'audit'`.

### 3. `hats verify` — deep health check, split from `hats doctor`
**Why now:** `hats doctor` is a quick + non-destructive health pass. A deeper `hats verify` could parse credentials JSON, check expiry horizons, verify `claude`/`codex` binary versions against a known-compatible matrix, and ping the provider's auth endpoint (lightweight HEAD). Operator could `hats verify` before a long session to pre-empt surprises.
**Scope:** days. Depends on what "deep" should cover — TBD but a reasonable v1 cut.
**Blocker:** none. Mostly a scoping decision.

### 4. Cross-provider symmetry audit script — fleet_scope hygiene (A-22/B-11/A-28)
**Why now:** Case-law B-11 (sharpened by A-28) requires reliability-class fixes to be audited across sibling providers. hats has `claude` + `codex` as siblings. A `scripts/hats-fleet-symmetry-check.sh` that runs tests symmetrically on both provider dispatch paths and flags suspicious asymmetries would mechanize the rule at the source, not rely on author discipline per-commit.
**Scope:** hours.
**Blocker:** none.

### 5. `hats list` filters (`--rc-only`, `--expired`, `--provider claude`)
**Why now:** `hats list` currently dumps all accounts. For operators with 5-10 accounts across two providers, filtering by Remote-Control scope / expiry / provider is quality-of-life. The token-info parser already extracts the signals; filter flags are flag-plumbing on top of the existing loop.
**Scope:** hours.
**Blocker:** none.

### 6. Provider abstraction refactor — groundwork for v2.0 (cursor, windsurf)
**Why now:** v2.0 goal is multi-provider beyond claude+codex. The current `case "$CURRENT_PROVIDER" in` branches are scattered through `hats`; pulling them into a provider-descriptor table (auth file, runtime env var, runtime command, base config template, auth flow) would make adding cursor or windsurf a data change rather than a code change. Low risk if kept internal + behind the same external API.
**Scope:** days.
**Blocker:** none conceptually; would benefit from operator feedback on which third provider matters most.

### 7. Encrypted credential backend (age, gpg, OS keychain) — v2.0 foundation
**Why now:** SECURITY.md flags plaintext-on-disk as the biggest unaddressed risk. Also a direct dependency for item #1 (export/import) and future team-credential-sharing. Age is the most operator-friendly choice; implementation is a thin wrapper around `age` invocations.
**Scope:** weeks (design + implementation + test + migration path).
**Blocker:** operator crypto choice (same choice as #1).

### 8. Token refresh telemetry — `hats doctor --metrics`
**Why now:** knowing which accounts have refreshed in the last N days surfaces dormant / dead credentials before the operator needs them. Auxiliary to #2 audit log but focused on token freshness rather than swap events.
**Scope:** hours. Reads the same `_token_info` output `_show_account_status` parses.
**Blocker:** none.

### 9. macOS CI: pure-BSD userland lane
**Why now:** current `macos-latest` GitHub Actions runners ship GNU grep + GNU coreutils by default; that masked the `grep -oP` BSD-incompatibility I caught in commit 48fc27e. A separate job that unsets Homebrew PATH prefixes and runs with pure BSD userland would catch the next portability regression at CI time instead of at user time.
**Scope:** hours. Mostly a PATH-scrubbing step + shelling-out-guards in CI.
**Blocker:** none. Low ROI unless another BSD-incompat is actually likely.

### 10. Team credential sharing via encrypted git repo (from Future Ideas)
**Why now:** aspirational v2.0+ feature. Depends on #1 + #7. Valuable for agencies / teams with multiple Claude Code subscriptions to share. Out of scope until crypto is settled.
**Scope:** weeks.
**Blocker:** chain — #7 → #1 → this.

---

## v0.1

Plaintext credential files with flock-based swapping.

- [x] Named account management (add, remove, list)
- [x] flock-serialized credential swaps
- [x] Automatic default account restore on exit
- [x] Vault backup/restore
- [x] Token status inspection (expiry, refresh, remote-control scope)
- [x] Shell integration (shell-init)
- [x] Stash/unstash for adding new accounts
- [x] Configurable via environment variables

## v0.2

Identity-aware account switching.

- [x] Profile identity swap — save/restore cached user identity (displayName, email) per account
- [x] Save refreshed tokens back to account file after swap session
- [x] `./bump <major|minor|patch>` dev script for semantic versioning
- [x] Credential & profile contamination detection in `hats fix`

## v1.0 (Current)

Per-account `CLAUDE_CONFIG_DIR` isolation — complete architecture rewrite.

- [x] Each account gets its own config directory (no more credential swapping)
- [x] Concurrent sessions are inherently safe (no locking, no races)
- [x] `base/` template directory with shared resources via symlinks
- [x] `hats link` / `hats unlink` — selectively share or isolate any resource
- [x] `hats status` — show linked vs isolated resources per account
- [x] Automatic migration from v0.2.x via `hats init`
- [x] `~/.claude` symlink to default account (bare `claude` still works)
- [x] No `flock` dependency — works on macOS and Linux without extra packages
- [x] Provider-scoped directory structure (`~/.hats/claude/`) for future expansion

### Removed (no longer needed)

- Credential file swapping and flock locking
- Save-back logic (was root cause of credential corruption)
- Profile save/restore (each account has own `.claude.json`)
- Stash/unstash (accounts have isolated directories)
- Vault backup/restore (account directories are self-contained)
- Contamination detection (contamination is architecturally impossible)

## v1.1

Quality-of-life improvements.

- [x] Codex provider support via per-account `CODEX_HOME`
- [x] Provider-aware `hats <provider> ...` command routing
- [x] Codex-safe default sharing model (`config.toml`, `plugins/`, `skills/`, `prompts/`, `rules/`)
- [x] Codex file-based auth bootstrap (`cli_auth_credentials_store = "file"`)
- [x] `hats doctor` — comprehensive health check (python3 version, file permissions, symlink integrity)
- [x] Colored output (with `--no-color` flag)
- [x] Tab completion for zsh and bash
- [ ] `hats export` / `hats import` — portable credential transfer between machines

## v2.0

Multi-provider support and encrypted storage.

- [ ] Broader provider abstraction (`~/.hats/cursor/`, `~/.hats/windsurf/`)
- [ ] Encrypted credential backends (age, gpg, OS keychain)
- [ ] `hats encrypt` / `hats decrypt` for credential files

## Future Ideas

- Team credential sharing via encrypted git repos
- Audit logging with timestamps
