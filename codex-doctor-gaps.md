# Codex doctor E2E gap analysis — 2026-04-21

Author: hats-codex-engineer (ag-bfc2b02fce6e6809)
Scope: E2E verification of codex-credentialed accounts. Working note — NOT a
roadmap item, NOT user-facing doc. Synthesis target: hats-lead.

## Current coverage — where codex checks live today

Codex reliability signal is split across two commands, not one `_doctor_codex`:

### `hats codex doctor` (layout)
All checks are shared with claude, provider-switched by `$CURRENT_PROVIDER`
inside `cmd_doctor` (hats:1673-1987). For codex specifically:

- §1 tooling: `python3` + `codex` on PATH
- §2 layout: `$HATS_DIR/codex` + `$HATS_DIR/codex/base`
- §2c orphan-isolated: reject `auth.json` / `config.toml` in `base/`
- §2f suspicious symlinks resolving outside `$HOME`
- §3 default-account runtime symlink (`~/.codex` → `$HATS_DIR/codex/<default>`)
- §4a primary auth file (`auth.json`) presence + mode-600/400
- §4b broken symlinks in account dir
- §4c missing expected shared resources (plugins/prompts/rules/skills)
- §4d locally-modified shared resources (drift from base)

§2b/§2d/§2e (JSON parse, hook-command resolution, duplicate-hook dedupe) are
gated `$CURRENT_PROVIDER = claude` — legit structural variance (codex has no
claude-code-style settings.json hooks). Per fleet_symmetric_improvement,
this is `claude-only` by-design, not a B-11 target.

### `hats codex verify` (semantic, 076ac9e)
`_verify_one_account` codex arm (hats:2691-2740):

- JSON parse
- File mode 600/400
- `tokens` key present → account_id echoed on PASS
- `config.toml` `cli_auth_credentials_store=file` (PASS/WARN/FAIL)

## E2E expectation (from hats-lead brief)

1. auth credentials file parses → **covered** (verify §1)
2. ChatGPT OAuth refresh-token fresh, not expired → **NOT covered**
3. codex CLI can invoke a model with stored creds → **NOT covered**

## Concrete gap: codex auth.json carries more than account_id

Live probe against `/home/tanwa/.codex/auth.json` on debussy (2026-04-21):

```
top-level: auth_mode, OPENAI_API_KEY, tokens, last_refresh
tokens:    id_token (JWT), access_token, refresh_token, account_id
```

Decoded id_token payload fields: `exp`, `iat`, `auth_time`, `sub`, `email`,
plus OpenAI-specific `https://api.openai.com/auth`.

On this box:
- id_token `exp`: 2026-04-06 (**-347h from now — expired 14 days ago**)
- `last_refresh`: 2026-04-06T15:36:29Z (15 days ago)
- `codex login status` → "Logged in using ChatGPT" exit 0

So: id_token is stale AND codex still auth-works, because the refresh_token
path auto-rotates at next API call. The present `hats codex verify` green-
flags this account on the single signal "tokens.account_id present",
which is correct in this case but would ALSO green-flag a corrupted
refresh_token with a stale id_token — a case where codex would fail at
first invocation but `verify` would report PASS.

## Gap summary (three items, reliability-class, fleet_scope=codex-only)

### G1. id_token expiry horizon + refresh-token presence
Mirrors what `verify` already does for claude (hats:2626-2690). Codex
equivalent:
- Decode `tokens.id_token` JWT payload (base64url middle part), read `exp`.
- PASS if `exp > now`.
- WARN if expired but `tokens.refresh_token` present AND `last_refresh`
  within a configurable window (propose 30 days — OpenAI refresh tokens
  rotate; >30d stale is suspicious).
- FAIL if expired AND (no refresh_token OR last_refresh > 90 days).

No new primitives required. The claude arm already has the shape; codex
arm just needs a JWT-payload parse step added before the current
"tokens present" check. Same python-heredoc idiom.

### G2. `codex login status` liveness probe
Cheap, read-only, non-billing, server-side auth validation. `codex login
status` exits 0 with "Logged in using ChatGPT" (or "Logged in using API
key") when tokens are server-side-valid; nonzero otherwise. Respects
`$CODEX_HOME`, so per-account invocation is:

```
CODEX_HOME="$acct_dir" codex login status
```

This is the true E2E check. It costs one HTTPS round-trip, no model call,
no billing. Propose adding this to `hats codex verify` as a final
per-account check after JWT-horizon. WARN on network failure (don't
hard-fail offline operators); FAIL on explicit "not logged in" / nonzero
exit when reachable.

### G3. `auth_mode` sanity
`auth.json.auth_mode` values seen in-field: `chatgpt`, `api_key`,
`device_auth`. Each has different invariants:
- `chatgpt` / `device_auth`: OAuth tokens required; `OPENAI_API_KEY`
  typically null.
- `api_key`: `OPENAI_API_KEY` non-null; tokens optional.

Current verify doesn't cross-check the declared `auth_mode` against the
actual content — so an `api_key`-mode file with a null `OPENAI_API_KEY`
would WARN only on "tokens key present" rather than the real issue.

Propose: after JSON parse, read `auth_mode` + assert the mode-specific
required fields. Low-cost (pure string / null check). WARN only.

## Gap FIX disposition

G1 + G3 are small, clear, structural-precondition-free — shippable in
this branch without new codex-CLI primitives. Mirror claude verify shape.
Smoke coverage: add test cases for (expired id_token + refresh_token
present), (no refresh_token + expired id_token), (api_key mode).

G2 is also small but carries a network dependency — network-timeout
handling + offline-tolerance policy should be discussed with hats-lead
first. My proposal: treat network-failure as WARN (matches the kimi
doctor §3 HTTP-status tolerance pattern in commit 8746d5a).

## `_token_info_codex` symmetry tail

`_token_info_codex` (hats:651) drives `hats list` / `_show_account_status`,
a separate surface from verify. Adding expired-marker semantics there
would give operators at-a-glance staleness signal in `hats codex list`,
matching the `EXPIRED` marker claude gets. Non-blocking for this audit
but worth noting for a future reliability-class pass. `fleet_scope:
fleet-wide` if taken up — mirrors existing claude behaviour.

## Fleet-symmetry verification

Per feedback_fleet_symmetric_improvement: G1 is a codex-side parallel to
existing claude `token expiry horizon` check (already present in
cmd_verify claude arm). The pattern is symmetric both ways: claude has
the JWT-equivalent check; codex didn't. Fixing codex closes that asymmetry.
`fleet_scope: codex-only` — the fix is one-sided catch-up, not a
fleet-wide change. G2 is codex-only by structural precondition (claude
has no equivalent `claude login status` primitive — auth liveness is
implicit in successful `claude` invocation). G3 is codex-only (no
`auth_mode` concept on claude). All three gaps pass A-28 fleet-scope
check.
