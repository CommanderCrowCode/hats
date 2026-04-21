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

### 1. `hats export` / `hats import` — portable credential transfer  (v1.1 closer)  ✅ SCAFFOLD SHIPPED 2026-04-20
**Status:** crypto-agnostic scaffold landed end-to-end. `hats export <name> [--out <file>|-] [--no-encrypt] [--include-sessions]` builds a MANIFEST.json + isolated-files tarball; `hats import <file> [--as <newname>] [--force]` validates manifest, rejects path-traversal, restores credentials with mode 600 preserved, then re-wires shared base symlinks via `_setup_account_dir`. Backend dispatch implements: `none` (raw, with prominent stderr warning); `age` (password-based via `age -p`, env-overridable via `HATS_EXPORT_PASSWORD`). Default is `age` if installed; if not, refuses with actionable guidance to install age or pass `--no-encrypt`. Smoke `test_export_import_roundtrip` covers byte-equal credentials/`.claude.json` after roundtrip, `--as` rename, `--force` guard, path-traversal rejection. Operator's age/gpg/keychain decision is now scoped down to "pick the encryption defaults"; the bash plumbing + manifest schema + import safety guards are done. MSH-11 closed.

### 2. Audit log — timestamped swap / add / remove history  ✅ SHIPPED 2026-04-19
**Status:** landed as opt-in JSONL audit log. Enable via `HATS_AUDIT=1`; reader is `hats audit` with `-n <count>` and `--raw` flags. Events: add / remove / rename / default / swap / link / unlink. Read-only commands (list / doctor / status / help / version) are NOT logged — signal hygiene on shared machines. Tests in `tests/smoke.sh::test_audit_log_opt_in_records_mutations_and_skips_reads`. Threat-model note: SECURITY.md's "No audit logging" gap now has a concrete answer for multi-user dev boxes. Commit: see `git log --grep 'audit'`.

### 3. `hats verify` — deep health check, split from `hats doctor`  ✅ SHIPPED 2026-04-20
**Status:** v1 landed. `hats verify [<account>|--all]` complements doctor's layout checks with deep per-account token semantics: JSON well-formedness, credential file mode (600/400), provider-specific parse (claude `claudeAiOauth` horizon + refreshToken presence + RC-scope; codex `tokens` + `cli_auth_credentials_store=file`), provider CLI version echoed. WARN/FAIL discipline: expired-with-refresh is WARN (auto-recovers); expired-without-refresh is FAIL (operator must re-login); non-JSON is FAIL. Exit 0 clean / 1 any issue. Read-only; never mutates state. Smoke `test_verify_command` covers happy path + expired-with-refresh WARN + non-JSON FAIL + unknown flag + missing account. Symmetry audit picked up 22 checks (was 21) — verify adds a provider-agnostic surface probe.

### 4. Cross-provider symmetry audit script — fleet_scope hygiene (A-22/B-11/A-28)  ✅ SHIPPED 2026-04-19
**Status:** landed as `scripts/hats-fleet-symmetry-check`. Three passes: (A) every `case "$CURRENT_PROVIDER"` block in `hats` has both `claude)` and `codex)` arms; (B) informational count of single-provider `if`-gates and `test_{claude,codex}_*` names with wide-skew warnings; (C) runtime symmetric smoke on the provider-agnostic command surface (`providers`, `help`, `version`, `completion bash|zsh`, `init`, `list`, `doctor`, `status nonexistent`, `default`-empty) — each pair must converge on the same rc. Caught one real asymmetry on first run: `_ensure_account_defaults` only branched `claude)`, fixed with an explicit codex no-op arm. Smoke suite calls `--static` to fence regressions. Flags: `--static` / `--runtime` / `--json` / `--quiet`. Exit 0 all-pass, 1 any-fail.

### 5. `hats list` filters (`--rc-only`, `--expired`, `--provider claude`)  ✅ SHIPPED 2026-04-19
**Status:** landed. `hats list` accepts `--rc-only` (RC-scope claude tokens), `--expired` (past-expiry), `--provider <claude|codex>` (reroute the listing tree), plus `--help`. Filters compose with AND semantics; the output renders a `Filters: --flag1 --flag2` header and an `X of Y account(s) matched` summary when any predicate is active. Unknown flags fail fast with `Error: Unknown list flag '--foo'` + usage. Implementation: `_account_passes_list_filters` helper parses the existing `_token_info` key=value stream; zero regressions on the 39-test smoke suite. New coverage `test_list_filter_flags` exercises --help, each predicate, AND-composition, bogus-flag rejection, and --provider codex reroute.

### 6. Provider abstraction refactor — groundwork for v2.0 (cursor, windsurf)  🚧 PHASE 1 SHIPPED 2026-04-20
**Status:** Phase 1 slice landed — `_call_provider_variant <base-func> [args...]` generic-dispatch helper centralizes the per-provider-function-name convention so callers don't need a case statement for each dispatch site. First migration: `_token_info` collapses from a case-on-provider block to a single line. Missing-variant path dies loudly so the fleet-symmetry-check script still mechanizes the coverage rule at commit time. Symmetry audit drops from 22 → 21 checks (one case block eliminated); everything still green.
**Phase 2 (future):** migrate the remaining 8 per-provider case blocks (login hints, add-failure hints, provider login, provider command, init, _show_account_status, _ensure_account_defaults, _configure_provider's scalar-field setup) onto the same helper. Each migration is a ~5-line refactor. Adding a new provider (cursor, windsurf) after Phase 2 collapses to: (a) add to `_is_supported_provider`, (b) write `_<hook>_<newprovider>` functions. No touching dispatch sites.
**Scope remaining:** days for full Phase 2.
**Blocker:** none conceptually; would benefit from operator feedback on which third provider matters most.

### 7. Encrypted credential backend (age, gpg, OS keychain) — v2.0 foundation
**Why now:** SECURITY.md flags plaintext-on-disk as the biggest unaddressed risk. Also a direct dependency for item #1 (export/import) and future team-credential-sharing. Age is the most operator-friendly choice; implementation is a thin wrapper around `age` invocations.
**Scope:** weeks (design + implementation + test + migration path).
**Blocker:** operator crypto choice (same choice as #1).

### 8. Token refresh telemetry — `hats doctor --metrics`  ✅ SHIPPED 2026-04-19
**Status:** landed. `hats doctor --metrics` adds a `Metrics — token freshness:` section under the existing health checks. Each account row shows `last refresh Nd ago (YYYY-MM-DD)`, derived from `.credentials.json` mtime (a strong "last activity" proxy because hats writes the refreshed token back at end-of-session). Dormancy WARNs: `WARN dormant` at >30d, `WARN very dormant` at >90d. Symmetric across claude + codex providers (both use the same mtime-based helper). Bare `hats doctor` is byte-identical to before — no behavior change without the flag. Smoke: `test_doctor_metrics_flag` covers (a) bare doctor doesn't emit the section, (b) section header + per-account lines render, (c) dormant + very-dormant tags fire on backdated accounts, (d) `--bogus` rejects with non-zero rc.

### 9. macOS CI: pure-BSD userland lane  ✅ SHIPPED 2026-04-20
**Status:** landed as a third job `smoke-macos-bsd` in `.github/workflows/smoke.yml`. Scrubs PATH to `/usr/bin:/bin:/usr/sbin:/sbin` before running syntax check, smoke suite, and basic surface probes — so tests run under the BSD versions of grep/sed/stat/awk that actual macOS users get, not the Homebrew-shadowed GNU versions the default runners use. Reports the active userland versions for visibility. The next BSD-incompat regression (see commit 48fc27e for the class) now fails at CI time instead of at user time.

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

---

## Shipped attribution corrections

### 2026-04-21 — codex verify G1+G2+G3 (codex-provider parity surge)

The codex-side verify hardening shipped as two logical pieces across two
git commits, not cleanly partitioned:

- **G1 (id_token JWT expiry horizon + refresh_token freshness) + G3
  (auth_mode sanity cross-check)** — landed as its own commit
  `160ff35 feat(verify): codex id_token JWT expiry + auth_mode sanity
  (G1+G3)`. Authored by hats-codex-engineer. Body carries first-cycle
  B-9 evidence: debussy `astartes` account (renamed from `tanwa` 2026-04-21 per praetor directive msg-efd95a3f63ce2c50) pre-commit silent PASS,
  post-commit WARN `id_token expired (-322.39h), last_refresh 13.5d
  ago, will auto-refresh`.

- **G2 (`codex login status` server-side liveness probe, WARN-on-network-
  failure policy)** — landed atomically inside `fbe77ed
  feat(codex-kimi): add OpenAI-compat Kimi wrapper for codex`. Shared-
  working-tree coordination with hats-kimi-engineer resulted in G2's
  in-flight edits being picked up by their concurrent `git commit`.
  G2 code (probe + smoke stub-bin + runner entries) is correct and
  live; attribution was not partitioned. Code-wise equivalent to a
  separate commit; history-wise blended. Choice to accept-as-shipped
  rather than force-push a revert: blast radius of rewriting main with
  a peer's work mid-flight is not justified when the code itself is
  correct and pushed.

Lesson for shared-tree coordination: when two engineers share a working
tree on the same host, the committer should `git status` before `git
commit -a` and stage explicit files rather than swallow unstaged edits
authored by the other engineer. Documented here so future sessions can
reference the pattern.
