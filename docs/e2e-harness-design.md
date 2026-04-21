# E2E Harness Design Note — Cross-Provider Integration Testing

**Date:** 2026-04-21
**Author:** hats-e2e-engineer (ag-7aeab07b8639266a, debussy)
**Status:** Draft — read-pass gate by hats-lead (ag-256b34a6fa4d04e9). No harness code until sign-off.
**Scope:** Design-only. §14 propose-and-proceed, silence=approval per §6.

---

## TL;DR

hats has three reliability surfaces today — `tests/smoke.sh` (96 sandboxed unit-style tests), `scripts/hats-fleet-symmetry-check` (cross-provider static + sandboxed runtime audits), and `scripts/hats-consistency-smoke` (cross-credential layout checks on the real `~/.hats`). All three run **hermetically** or on **layout-only** signal.

What's missing is a **fleet-wide live probe layer**: does each real credential (claude-shannon/monet/debussy + codex-slaanesh + kimi) actually invoke its provider end-to-end? The current reliability stack tells us the bytes are well-formed; it doesn't tell us the token still authenticates against the live API.

This note proposes `scripts/hats-e2e-probe` + a one-command runner `scripts/hats-ship-gate` that chains smoke + symmetry + consistency + e2e into a single regression check. Bounded-time, deterministic, network-failure = WARN (kimi doctor §3 convention from 8746d5a).

---

## 1. What exists today (inventory)

| Surface | Path | Scope | Network? |
|---------|------|-------|----------|
| Sandboxed unit-ish regression | `tests/smoke.sh` | 96 tests, `HATS_DIR` + `HOME` sandbox, fake creds | No |
| Cross-provider static + runtime audit | `scripts/hats-fleet-symmetry-check` | case-arm + if-gate symmetry + sandboxed rc parity | No |
| Cross-credential layout on real `~/.hats` | `scripts/hats-consistency-smoke` | symlink integrity, no invocations | No |
| Per-account semantic verify | `hats verify [--all]` | JWT horizon, file mode, parse; codex `login status` probe at ≥160ms2 (G2 landed at 160ff35) | **Yes — one HTTPS per codex account** |
| Kimi provider handshake | `hats [codex] kimi doctor` | §3 base-URL reachability with rc=000 ⇒ FAIL-unreachable (commit 8746d5a) | **Yes — one HTTPS per kimi invocation** |

**Gap:** nothing runs a provider-agnostic **same-task canary** across the four-credential fleet and compares outputs for parity regressions. That's what this harness adds.

---

## 2. E2E harness components

### 2.1 `scripts/hats-e2e-probe` — fleet canary (NEW)

One-shot invocation against each registered credential, comparing outputs for parity regressions.

**Probe contract:**
- **Task:** a minimal deterministic-ish prompt. Candidate: "Reply with exactly the three characters: ok.`" (no newlines, no model-version commentary). Tolerates per-model formatting variance.
- **Scope:** per `HATS_E2E_SCOPE` env var — `claude` (shannon/monet/debussy), `codex` (astartes/slaanesh), `kimi` (both claude-kimi and codex-kimi wrappers), or `all` (default).
- **Bounded time:** per-probe default timeout = 30s (env `HATS_E2E_PROBE_TIMEOUT`). Fleet-wide ceiling = `probes × timeout` with explicit wall-clock cap = 180s (env `HATS_E2E_WALL_TIMEOUT`).
- **Determinism:** the probe's only PASS condition is (a) exit 0 AND (b) output contains the literal 2-char token `ok`. It does NOT compare outputs for byte-equality across models — that would false-positive on formatting variance.
- **Network-failure policy:** rc=000/timeout/DNS-fail = **WARN**, not FAIL. Matches kimi doctor §3 (8746d5a) + codex verify G2 (160ff35). Offline-tolerant.
- **Model selection:** minimum-cost variant per provider (e.g. claude haiku-4.5 via `--model claude-haiku-4-5-20251001`, codex gpt-5 low-reasoning, kimi K2.5 default). Explicit so probe cost is bounded and predictable.
- **Side effects:** none beyond provider-side token refresh. No file writes, no persistent state in `~/.hats`.

**Output shapes:**
- Human (default): one line per probe — `PASS/WARN/FAIL <provider>/<account> (rc=0, 2.1s, model=...)`.
- `--json`: array of `{provider, account, status, rc, duration_ms, err_excerpt, probe_token_hit}`.
- `--quiet`: summary line only.

**Flags (proposed):**
- `--scope <claude|codex|kimi|all>` — subset filter
- `--account <name>` — single-account probe
- `--json` / `--quiet` — output modes
- `--max-wall <sec>` — override ceiling
- `--no-network-warn` — escalate network-fail to FAIL (for `--strict` CI mode, not default)
- `-h|--help`

**Budget (Backend API):**
- 3 claude accounts × 1 invocation = 3 HTTPS + 3 messages (haiku ≈ ¢0.03 / probe ≈ $0.10 fleet probe).
- 1 codex account × 1 invocation = 1 call (gpt-5 low-reasoning ≈ ¢1 / probe).
- 2 kimi wrappers × 1 invocation each = 2 calls (kimi K2.5 ≈ ¢0.1 / probe).
- **Total ceiling:** ~$1 per fleet-wide probe. Design target: runnable ≤10×/day without operator guilt. If operator later says "probe on every commit", cost is still within development-noise.

### 2.1.1 Installed-vs-source drift probe (NEW, per lead guidance 2026-04-21)

**Context:** `feedback_installed_vs_source_drift.md` memorialized a 2026-04-21 stale-install incident where `./hats kimi doctor` reported 5/5 green but fresh tmux panes hit the old emitted function because `~/.local/bin/hats` was stale. `tests/smoke.sh` uses `$HATS_SCRIPT` (repo root) and misses this entire class.

**New smoke test:** `test_install_then_invoke_through_PATH` — runs `install.sh` into a sandboxed `$HOME/.local/bin`, then re-invokes a changed emitted function through PATH with a fresh zsh subshell, and asserts the emission matches the current source (e.g. grep for commit hash or known-changed string in `type <fn>` output).

**Fit in the ship-gate:** smoke (step 1), not e2e (step 4). Install is hermetic and deterministic — no network dep. Goes under `tests/smoke.sh` alongside the existing `test_install_to_sandbox_stamps_commit`, not in the new e2e-probe script.

**Complementary e2e-probe hook:** `hats-e2e-probe --via-path` flag — optionally invoke through PATH rather than `$HATS_SCRIPT` for the fleet canary. OFF by default (smoke already covers the unit-level regression); ON for explicit end-to-end operator-experience validation in CI.

### 2.2 `scripts/hats-ship-gate` — one-command runner (NEW)

Chain-runner that executes the full regression stack in order and aggregates results. Stops early on FAIL in the "hard" chain but continues through "soft" chain for visibility.

**Chain shape:**

```
1. tests/smoke.sh                            [hard — any FAIL blocks;
                                               now includes test_install_then_invoke_through_PATH]
2. scripts/hats-fleet-symmetry-check         [hard — any FAIL blocks]
3. scripts/hats-consistency-smoke            [hard — any FAIL blocks]
4. scripts/hats-e2e-probe                    [soft — WARN on network, FAIL on token failure only]
```

**Rationale for soft chain at step 4:** E2E is the only stage that depends on external network + valid live credentials. Operators running locally without network access, or devs on fresh clones without an account roster, shouldn't be forced to populate credentials to run the rest of the gate. The gate exits nonzero ONLY if steps 1-3 FAIL or step 4 returns non-network FAIL.

**Flags:**
- `--no-e2e` — skip step 4 entirely
- `--only <stage>` — run one stage (`smoke`/`symmetry`/`consistency`/`e2e`)
- `--strict` — escalate step-4 network-WARN to FAIL (CI-intended)
- `--json` — structured output
- `-h|--help`

**Exit codes:**
- 0 — all steps pass (step 4 WARN allowed under default, unless `--strict`)
- 1 — any hard-chain FAIL, or step 4 FAIL under `--strict`
- 2 — usage / env error

---

## 3. Coordination with adjacent test surfaces

### 3.1 hats-codex-engineer (ag-bfc2b02fce6e6809)

**Already shipped in codex verify suite (160ff35 + doctor-gaps doc):**
- G1 — id_token JWT expiry + refresh-token presence (codex-only, matches claude JWT-horizon check)
- G3 — auth_mode sanity (codex-only, no claude analog)
- G2 — `codex login status` liveness probe (pending; WARN-on-network convention established)

**Boundary rule (proposed to codex-engineer via msg 04:00:43Z):**
- codex-engineer OWNS intra-provider semantic checks (everything in `hats codex verify` / `hats codex doctor`).
- e2e-engineer CONSUMES the aggregate rc signal at fleet-wide level in `hats-ship-gate` step 2 (symmetry-check) + step 4 (e2e probe).
- No duplication of JWT-horizon or auth_mode checks at the e2e layer. The e2e probe assumes verify-semantic PASS as a precondition; it tests the surface above that.

### 3.2 hats-kimi-engineer (ag-1755a24ecbfb4a95)

**Already shipped:**
- Kimi base-URL reachability probe in `hats kimi doctor` with rc=000 FAIL-unreachable convention (8746d5a).
- codex-kimi OpenAI-compat sibling wrapper at api.moonshot.ai/v1 (fbe77ed).
- Kimi's hasCompletedOnboarding + base URL contract documented in mesh memory.

**E2E probe coverage for kimi:**
- Both claude-kimi and codex-kimi wrappers are probed. Distinguishing them at probe time requires scope filter `--scope kimi` to list both wrapper variants.
- WARN on rc=000 / network / DNS, matching doctor §3.
- Will ping kimi-engineer for any known K2.5-specific canary prompt gotchas before first implementation.

### 3.3 hats-mirror-engineer (ag-1016b6fbf869d5c2)

**Dependency direction:** mirror-engineer consumes provider-rules YAML from Stream A. The e2e harness itself is INDEPENDENT of the mirror tooling — they ship on parallel tracks. The only intersection is the rule-list research output feeding their design doc.

---

## 4. Explicitly out of scope (to bound the design)

- **Model-output correctness testing.** Not probing "does claude understand semantics" — only "does auth still work, CLI still invokes, and provider returns a non-empty reply". Semantic correctness is a different project.
- **Regression of provider-native behavior.** If claude-sonnet-4-6 changes its response formatting, the probe tolerates via the substring-contains match on `ok`. We do not diff historical outputs.
- **Automated credential rotation.** If a probe FAILs with token-expired, the harness reports — it does not run `hats login` or equivalent.
- **Continuous monitoring.** No daemon, no cron. Operator-triggered or CI-triggered only. Matches hats' "no persistent services" philosophy.
- **Cost tracking / billing telemetry.** Out of scope for v1. If operator later requests, add `--track-cost` flag that logs to a rolling JSONL.

---

## 5. Implementation ordering (post sign-off)

1. **Probe prototype (single provider):** `scripts/hats-e2e-probe --scope claude --account <default>` end-to-end, bounded timeout, --json output shape locked.
2. **Expand to all three provider scopes** with symmetric code path via `_call_provider_variant` helper (5f1e3e7) or equivalent. Verify fleet-symmetry-check's static audit does NOT regress.
3. **Ship-gate runner** chaining the four stages with soft/hard exit-code logic.
4. **Smoke coverage** — add `test_e2e_probe_offline_warns` + `test_e2e_probe_token_fail` to `tests/smoke.sh` using sandboxed provider-command stubs (no real network in unit test layer).
5. **README mention** — one sentence + link to this doc under an "E2E regression" subsection.

Each slice is independently shippable. No integration big-bang.

---

## 6. Open questions for hats-lead

1. **OK on the probe prompt "Reply with exactly the three characters: ok."?** Alternative: no-op prompt that tests auth-only via `claude --help` / equivalent doesn't work because it doesn't exercise the token path. A 2-token echo-style probe is the minimum viable.
2. **`--strict` as default in CI?** Proposed default is lenient (network WARN allowed); CI explicitly opts into strict. Flag matters because the GitHub Actions runners CAN reach Anthropic + OpenAI + Moonshot, but Kimi's coding endpoint has had DNS-flake history. Lenient default is safer for developer-run; strict is safer for CI gate. Could split by invocation context instead.
3. **Fleet-wide cost ceiling for "CI on every PR"?** Rough estimate $1/probe × ~40 PRs/month = $40/month floor. Acceptable or should CI only probe on `main` merges?
4. **Probe account enumeration:** use `hats list --json` when present, else parse `$HATS_DIR/<provider>/` directly? Propose former — cleaner contract.

Silence = proceed with proposed defaults per §6.

---

## Appendix A — API contract sketch

`hats-e2e-probe --json` output:

```json
{
  "schema_version": 1,
  "started_at": "2026-04-21T12:00:00Z",
  "duration_ms": 18420,
  "scope": "all",
  "wall_timeout_sec": 180,
  "probe_timeout_sec": 30,
  "results": [
    {"provider": "claude", "account": "shannon", "status": "pass", "rc": 0, "duration_ms": 2103, "probe_token_hit": true},
    {"provider": "codex",  "account": "slaanesh", "status": "warn", "rc": 0, "duration_ms": 29987, "err_excerpt": "timeout after 30s"},
    {"provider": "kimi",   "account": "claude-kimi", "status": "pass", "rc": 0, "duration_ms": 1820, "probe_token_hit": true}
  ],
  "summary": {"pass": 5, "warn": 1, "fail": 0, "skipped": 0}
}
```

`hats-ship-gate --json` aggregates the four stage outputs under a top-level `stages: [{name, exit, duration_ms, detail_path}]` with an `overall: pass|warn|fail`.
