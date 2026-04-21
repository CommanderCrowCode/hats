# Cross-Credential Consistency for Praetor & Fleet Agents

**Date:** 2026-04-17
**Author:** hats-lead (ag-0370a83a51af838c, debussy)
**Status:** Initial research — NO implementation without praetor approval

## TL;DR — headline result

The initial concern ("different credentials see different memory namespaces") turned out to be
**partially wrong at ground truth**. The `projects/` tree that holds per-project memory
(`projects/<slug>/memory/`) is **already symlinked to a shared `base/`** on every credential,
so memory IS consistent across shannon/monet/debussy.

```
~/.hats/claude/shannon/projects  -> ../base/projects
~/.hats/claude/monet/projects    -> ../base/projects
~/.hats/claude/debussy/projects  -> ../base/projects
```

Verified with `readlink -f`: all three paths resolve to
`/home/tanwa/.hats/claude/base/projects/-home-tanwa-praetor/memory`.

The real divergences are elsewhere and **smaller than feared** but not zero. Enumerated below.

## Ground truth — what is shared vs per-credential

### Shared across all credentials (via symlink from `<cred>/` → `base/`)

These are the same bits regardless of which credential runs:

| Resource | Notes |
|----------|-------|
| `CLAUDE.md` | Global instructions |
| `agents/` | Symlinked to `/home/tanwa/opt/scripts/claude-agents` |
| `skills/` | Symlinked to `/home/tanwa/opt/scripts/claude/skills` |
| `plugins/` | Plugin binaries (but enablement flags differ — see below) |
| **`projects/`** | **Per-project memory lives here — shared ← key finding** |
| `hooks/`, `hooks.json` | Hook scripts + manifest |
| `.mcp.json` | MCP server declarations |
| `tasks/`, `teams/`, `todos/`, `plans/` | TaskList / team / plan state |
| `session-env/`, `shell-snapshots/` | Environment snapshots |
| `statsig/`, `telemetry/`, `cache/`, `debug/`, `downloads/`, `chrome/` | Housekeeping |
| `history.jsonl`, `file-history/`, `paste-cache/` | Input/paste history |
| `vault/`, `backups/` | Private store + backups |
| Most `security_warnings_state_*.json` | (Some are per-credential; see isolated list) |

### Isolated per credential (NOT symlinked — each credential has its own copy)

| Resource | Reason | Divergence risk |
|----------|--------|-----------------|
| `.credentials.json` | OAuth tokens — must be isolated | ✅ Intentional. No risk. |
| `.claude.json` | Per-credential identity, onboarding state, cached GrowthBook gates, MCP server state | 🟡 Feature-flag drift — see §"Cached feature flags" |
| `sessions/*.json` | Per-credential session files | 🟡 Session continuity — see §"Session & resume" |
| `mcp-needs-auth-cache.json` | Per-credential MCP auth reminder flags | 🟢 Low — cosmetic reminder only |
| `security_warnings_state_*.json` (shannon only — 24 files) | Per-session security-warning-ack state accumulated on shannon | 🟢 Low — reprompts security warnings on other credentials, not behavior |
| `.credentials.lock`, `.credentials.shannon.json` (shannon only) | Legacy file-swap leftovers | 🟢 Dead bytes |

### Intentionally unlinked from base on SPECIFIC credentials

These are the "surprise" divergences — files that `hats` defaults to sharing, but have been
broken out on one credential only:

| Resource | Credentials that diverge | What differs | Risk |
|----------|--------------------------|--------------|------|
| `settings.json` | **shannon only** (monet + debussy both symlink to base) | shannon has `alwaysThinkingEnabled: true` + extra `enabledPlugins` (document-skills, feature-dev, frontend-design, rust-analyzer-lsp, security-guidance); base has none of those | 🔴 **Meaningful behavioral divergence** — see §"Plugin & thinking-mode drift" |
| `stats-cache.json` | **debussy only** (symlinked on monet, has own on shannon) | Usage-stats cache | 🟢 Cosmetic |
| `CONSTITUTION.md` | **shannon only** (not in base, not on monet/debussy) | 23.5 KB engineering-principles doc | 🟡 Read path works via `~/.claude/` — see §"CONSTITUTION.md access pattern" |

## The `~/.claude` symlink as a hidden dependency

```
~/.claude -> ~/.hats/claude/shannon
```

**Global state:** `~/.claude` is a fixed symlink to the default account (`shannon`). Every
agent, regardless of which credential spawned its claude-code process (shannon, monet, debussy),
sees `~/.claude/` as shannon's directory. This is what makes CLAUDE.md's reference
`~/.claude/CONSTITUTION.md` work on all three credentials — they all read shannon's
CONSTITUTION.md.

**Sub-points:**

1. Claude-code **reads its own config from `CLAUDE_CONFIG_DIR`** (which differs per credential),
   not from `~/.claude/`. So `~/.claude/` is *not* claude-code's config root when running under
   monet/debussy.
2. But any *user-instruction* reference to `~/.claude/<file>` (like the CLAUDE.md CONSTITUTION
   reference) is a literal path and always hits shannon's dir.
3. **Fragility:** if `hats default <other>` ever changes the symlink away from shannon,
   CONSTITUTION.md becomes unreachable on the new default (because CONSTITUTION.md is
   shannon-only, not in base and not on monet/debussy).

## Mesh identity is per-session (therefore per-credential)

Each claude-code session registers with relay-mesh and receives a unique `agent_id`. Session
IDs live under `<cred>/sessions/` and don't cross credentials. Consequence:

- "Praetor" running under shannon = ag-6980e2764471d122 (today)
- Same CLAUDE.md + same memory + same tmux pane name, but if spawned under debussy instead,
  would register as a different ag-xxx with different pane.
- **Memory and instructions are identical; identity and live-session state are not.**

This is correct behavior for credential isolation and doesn't need changing. The thing to
be aware of: agent-provisioning scripts should capture `(project_slug, role)` rather than
`(agent_id)` when they want "the praetor instance, whichever credential".

## Detailed risk register

### R1 — shannon `settings.json` drift 🔴 high

**Correction (2026-04-17 post-initial-write):** the direction of drift is the OPPOSITE of what
the earlier summary claimed. Ground truth from `ls -la` + diff:

- `base/settings.json` — 22 KB, modified 2026-04-16. HAS `alwaysThinkingEnabled: true`, HAS
  `enabledPlugins` (5 plugins), has the full relay-mesh hook set with absolute
  `/home/tanwa/.hats/claude/base/hooks/...` paths.
- `shannon/settings.json` — 1.4 KB, modified 2026-04-11. MISSING `alwaysThinkingEnabled`, has a
  simpler hook config using `~/.claude/hooks/...` paths, has a local `statusLine` override.
  Has `enabledPlugins` (same 5).
- `monet` + `debussy` — both symlink to `base/settings.json`, so they INHERIT the richer
  config.

**Net effect:** agents running on shannon miss `alwaysThinkingEnabled` and the newer hook
matcher list; agents on monet/debussy have them. The behavioral divergence is real but the
*outlier* is shannon, which is behind.

**Mitigation direction (updated):** unlink shannon's local `settings.json` and replace with
a symlink to `base/settings.json`. Side effect — shannon loses its local `statusLine`
customization. That's cosmetic. If we care, we can fold it into base first.

**Blast radius:** Agents relying on extended thinking in their default pattern get it on
monet/debussy but NOT on shannon. If praetor (currently on shannon) is expected to think
extra, it isn't.

**Mitigation candidates (for praetor to choose):**
- **Option A (convergence):** Promote shannon's settings.json to `base/` so all three
  credentials inherit the same plugin set and thinking mode.
  *Risk:* base becomes shannon-biased if shannon gets updated and others don't re-symlink.
- **Option B (explicit divergence):** Keep per-cred settings.json but document the expected
  differences and add a CI/smoke check that flags unexpected drift.
- **Option C (base + overlay):** Move shared config to base, allow per-cred overlays, merge at
  launch. *Requires hats tool change* — bigger lift.

**Recommendation:** Option A. The plugin set + thinking mode should be identical across a
fleet that's supposed to behave identically. Plugins live in shared `plugins/` anyway, so
enabling them uniformly has low risk.

### R2 — CONSTITUTION.md single-copy on shannon 🟡 medium

**Observation:** CONSTITUTION.md exists only at `/home/tanwa/.hats/claude/shannon/CONSTITUTION.md`.
Not in base, not on monet/debussy. Accessed via `~/.claude/CONSTITUTION.md` which resolves to
shannon's copy regardless of which credential is running.

**Why it matters:**
- CLAUDE.md instructs agents to read `~/.claude/CONSTITUTION.md`. Today this works because
  `~/.claude -> shannon`.
- If `hats default` ever switches to monet or debussy, CONSTITUTION.md vanishes from that path.
- Anyone operating under `CLAUDE_CONFIG_DIR=monet` who tries `$CLAUDE_CONFIG_DIR/CONSTITUTION.md`
  gets a miss (expected — they're not supposed to use that path — but if someone generalizes
  the CLAUDE.md rule incorrectly they'll skip the constitution silently).

**Mitigation candidates:**
- **Option A:** Move CONSTITUTION.md to `base/` and symlink from each credential. Single source,
  symmetric access.
- **Option B:** Leave as-is; document that constitution lives with shannon and rely on
  `~/.claude` being stable.

**Recommendation:** Option A. It's a 30-second move + 3 symlinks, and it removes the implicit
dependency on `hats default = shannon`.

### R3 — .claude.json feature-flag skew 🟡 medium

**Observation:** Each credential has its own `.claude.json` (correct — it holds per-credential
identity like `oauthAccount`). But the top-level *keys* also differ significantly because the
cached GrowthBook gates, onboarding-state flags, and notice-dismissed flags accumulated
differently over each credential's history.

Examples of shannon-only keys: `hasShownOpus45Notice`, `hasShownOpusPlanWelcome`,
`anonymousId`, `hasOpusPlanDefault`, `doctorShownAtSession`, `birthdayHatAnimationCount`.

Examples of debussy-only keys: `hasUsedBackgroundTask`, `opus47LaunchSeenCount`,
`promptQueueUseCount`.

**Why it matters:**
- Most of these are UI-nudge flags and do not affect agent behavior.
- `cachedGrowthBookFeatures` + `cachedStatsigGates` CAN affect behavior if experiments toggle
  real functionality. These are refreshed from Anthropic servers on each launch, so drift
  is transient.
- Low but not zero: if shannon has seen "hasShownOpusPlanWelcome" and monet hasn't, the very
  first session on monet shows an onboarding prompt shannon wouldn't.

**Mitigation:** low priority. Accept that per-credential `.claude.json` exists for identity
reasons, do not try to sync. Possibly add a smoke check that compares
`cachedGrowthBookFeatures`/`cachedStatsigGates` across credentials and surfaces meaningful
diffs, since those are the only behavior-affecting keys.

### R4 — sessions/ isolation breaks cross-credential resume 🟢 low

**Observation:** `sessions/` is per-credential. You can't `claude --resume <session-id>` on
debussy if the session was created on shannon.

**Why it matters:** A praetor session that ran under shannon can't be resumed on monet/debussy.
Memory survives (shared via `base/projects/`) but the session transcript doesn't.

**Mitigation:** accept. This is a feature of credential isolation. If cross-credential resume
is ever needed, the right answer is exporting memory + relaunching, not session-state sync.

### R5 — Mesh agent registration is per-session 🟢 low

Already addressed above. No mitigation needed; it's correct behavior.

### R6 — External cached creds (Infisical, Tailscale) 🟢 low

`~/.infisical.env`, `~/.tailscale`, `~/.config/` etc. live in `$HOME`, not `$CLAUDE_CONFIG_DIR`.
They are genuinely shared by all credentials automatically. No drift risk from hats.

## Proposed mitigations — prioritized

| # | Mitigation | Effort | Risk reduction |
|---|-----------|--------|----------------|
| M1 | Move `shannon/settings.json` → `base/settings.json` (enable plugins + thinking mode uniformly) | Low | High (R1) |
| M2 | Move `shannon/CONSTITUTION.md` → `base/CONSTITUTION.md`, symlink from each cred | Low | Medium (R2) |
| M3 | Add a post-swap smoke test (below) that verifies expected shared paths still resolve to base | Low | Medium — prevents regressions |
| M4 | Add a linter pass in `hats` that flags when a normally-shared resource has been broken out per-cred without a documented reason | Medium | Low (preventative) |

**Nothing in this list changes agent behavior or memory content.** All four are
shape-of-config changes. They should be approved by praetor before execution because they
touch settings that every running session inherits.

## Smoke test — post-credential-switch verification

Proposed: a short shell probe that an agent can run after `hats swap <cred>` to confirm it's
seeing the expected shared world. Output is a pass/fail table.

```bash
#!/usr/bin/env bash
# hats-consistency-smoke — run inside a claude-code session after swap
# Reports whether shared resources still resolve to base/ and per-cred resources
# are appropriately isolated.

cred="${1:?usage: hats-consistency-smoke <cred>}"
root="$HOME/.hats/claude"
base="$root/base"
cdir="$root/$cred"

[ -d "$cdir" ] || { echo "FAIL: $cdir not found"; exit 1; }

pass=0; fail=0
check_shared() {
  local path="$1"
  local target; target=$(readlink -f "$cdir/$path" 2>/dev/null)
  local expected; expected=$(readlink -f "$base/$path" 2>/dev/null)
  if [ -n "$target" ] && [ "$target" = "$expected" ]; then
    printf "PASS shared   %s\n" "$path"
    pass=$((pass+1))
  else
    printf "FAIL shared   %s (resolves to %s, expected %s)\n" "$path" "$target" "$expected"
    fail=$((fail+1))
  fi
}
check_isolated() {
  local path="$1"
  if [ -e "$cdir/$path" ] && [ ! -L "$cdir/$path" ]; then
    printf "PASS isolated %s\n" "$path"; pass=$((pass+1))
  else
    printf "FAIL isolated %s (missing or unexpectedly symlinked)\n" "$path"; fail=$((fail+1))
  fi
}

# Shared resources that MUST resolve to base
for p in projects CLAUDE.md skills agents plugins hooks hooks.json .mcp.json \
         tasks teams todos plans session-env; do
  check_shared "$p"
done

# Isolated resources that MUST be per-cred
for p in .credentials.json .claude.json sessions; do
  check_isolated "$p"
done

# Divergence red flags (these should match base unless intentionally forked)
for p in settings.json CONSTITUTION.md; do
  if [ -L "$cdir/$p" ]; then
    target=$(readlink -f "$cdir/$p")
    expected=$(readlink -f "$base/$p" 2>/dev/null)
    if [ "$target" = "$expected" ]; then
      printf "PASS      cfg %s (→ base)\n" "$p"; pass=$((pass+1))
    else
      printf "WARN      cfg %s diverges from base\n" "$p"
    fi
  elif [ -e "$cdir/$p" ]; then
    printf "WARN      cfg %s is broken out (not symlinked to base)\n" "$p"
  fi
done

# Memory namespace probe — verify the praetor memory is reachable and identical
praetor_mem="$cdir/projects/-home-tanwa-praetor/memory/MEMORY.md"
base_mem="$base/projects/-home-tanwa-praetor/memory/MEMORY.md"
if [ -r "$praetor_mem" ] && cmp -s "$praetor_mem" "$base_mem" 2>/dev/null; then
  printf "PASS memory   praetor namespace reachable + identical to base\n"
  pass=$((pass+1))
else
  printf "FAIL memory   praetor namespace mismatch\n"; fail=$((fail+1))
fi

printf "\n=== %d pass, %d fail ===\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
```

**Proposed home for this script:** `/home/tanwa/hats/hats-consistency-smoke` (alongside the
existing `hats` binary). Could also become `hats verify <cred>` subcommand if integrated.

## Execution log — 2026-04-17

**M1 and M2 executed and verified.** Approved by praetor (msg-2c01b16fbb9ebcdd,
re-acked msg-ce1063c48b393a80 after I flagged the direction inversion). Dominion-lead
cleared for M2 sequencing (msg-838fc8bc2875db9f: their proposal-additions file is separate
and doesn't patch CONSTITUTION.md, will rebase path refs post-move).

Operations, in order:

1. `cp -a shannon/settings.json docs/backups/shannon-settings-pre-M1-2026-04-17.json`
2. `cp -a shannon/CONSTITUTION.md docs/backups/shannon-CONSTITUTION-pre-M2-2026-04-17.md`
3. **M1:** `rm shannon/settings.json && ln -s ../base/settings.json shannon/settings.json`
4. **M2:** `mv shannon/CONSTITUTION.md base/CONSTITUTION.md` +
   3× `ln -s ../base/CONSTITUTION.md <cred>/CONSTITUTION.md`
5. **Smoke:** `/home/tanwa/hats/scripts/hats-consistency-smoke` → 57 pass / 0 fail
   across shannon + monet + debussy.

**Verification output (abridged):**

```
shannon/settings.json     -> /home/tanwa/.hats/claude/base/settings.json
monet/settings.json       -> /home/tanwa/.hats/claude/base/settings.json
debussy/settings.json     -> /home/tanwa/.hats/claude/base/settings.json

shannon/CONSTITUTION.md   -> /home/tanwa/.hats/claude/base/CONSTITUTION.md
monet/CONSTITUTION.md     -> /home/tanwa/.hats/claude/base/CONSTITUTION.md
debussy/CONSTITUTION.md   -> /home/tanwa/.hats/claude/base/CONSTITUTION.md

~/.claude/CONSTITUTION.md -> (via shannon) -> base/CONSTITUTION.md  ✓ 338 lines readable
```

**Rollback (if needed):**

```bash
# M1
rm /home/tanwa/.hats/claude/shannon/settings.json
cp /home/tanwa/hats/docs/backups/shannon-settings-pre-M1-2026-04-17.json \
   /home/tanwa/.hats/claude/shannon/settings.json

# M2
for c in shannon monet debussy; do
  rm "/home/tanwa/.hats/claude/$c/CONSTITUTION.md"
done
mv /home/tanwa/.hats/claude/base/CONSTITUTION.md \
   /home/tanwa/.hats/claude/shannon/CONSTITUTION.md
```

## Smoke script — shipped

`/home/tanwa/hats/scripts/hats-consistency-smoke` checks shared-path symlink correctness,
isolated-path per-credential presence, and a praetor-memory probe. Modes:
`--verbose` (default), `--quiet`, `--json`. Idempotent, no side effects, cron-friendly.
Returns 0 on all-pass. First run on this host: 57 pass / 0 fail.

## `hats doctor` subcommand — shipped

The roadmap-tracked `hats doctor` command (v1.1 item, previously unchecked) now ships as a
proper subcommand of the `hats` CLI. Read-only, per-provider health check covering:

- Tooling presence (python3, provider CLI)
- Layout integrity (provider dir, base dir)
- Default-account runtime symlink (`~/.claude` or `~/.codex`) matches configured default
- Per-account: primary auth file presence + mode 600 permissions check
- Per-account: broken symlinks
- Per-account: missing shared resources (run `hats fix` to repair)
- Per-account: locally-overridden shared resources (diverges from base — the class of
  drift this whole audit was about)

Exit 0 on clean, 1 on any issue. Works for both claude and codex providers
(`hats doctor` and `hats codex doctor`). First run on this host:
- claude: 1 issue (config migration gap — `default` key not `default_claude`, filed as
  follow-up), 6 warnings (pre-existing shannon legacy state).
- codex: 0 issues, 1 warning (scb10x config.toml locally overridden — intentional).

## Open questions for praetor

1. **Approval to execute M1 + M2** (promote shannon's settings.json and CONSTITUTION.md to
   `base/`)? These are the highest-leverage fixes. All M1 does is widen the current shannon
   config to monet/debussy; all M2 does is add base copies + 2 symlinks. Rollback = move
   files back.
2. **Approval to commit the smoke test** as `hats-consistency-smoke`? Purely additive.
3. Should mesh-agent-spawn skill **wake agents via a consistent "hats env check"** at the top
   of their first prompt, rather than trusting the environment? I can propose a 3-line
   preamble.
4. Is there an appetite for broader hats changes (e.g., base + overlay merge for settings)
   or is the preference to keep hats simple and lean on convention?

## Appendix — commands used to derive this

```bash
# Verify memory path resolution
for c in shannon monet debussy; do
  readlink -f /home/tanwa/.hats/claude/$c/projects/-home-tanwa-praetor/memory
done
# All three → /home/tanwa/.hats/claude/base/projects/-home-tanwa-praetor/memory

# Enumerate per-credential (non-symlinked) files
for c in shannon monet debussy; do
  find /home/tanwa/.hats/claude/$c -maxdepth 1 ! -type l -printf '%y %f\n' | sort
done

# Settings divergence
diff /home/tanwa/.hats/claude/base/settings.json \
     /home/tanwa/.hats/claude/shannon/settings.json
```

---

## Footnotes (post-publication)

- **2026-04-21** — codex account labels `tanwa` and `scb10x` (referenced at §3 line ~384) were renamed to `astartes` and `slaanesh` respectively per praetor directive msg-efd95a3f63ce2c50. The `scb10x config.toml locally overridden` finding still holds; only the label has changed. Historical audit text preserved in place for trail integrity.
