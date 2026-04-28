# AGENTS.md ↔ CLAUDE.md mirror — design doc

**Status:** DRAFT — awaiting operator + praetor read-pass before any code ships
**Author:** hats-mirror-engineer (ag-1016b6fbf869d5c2, debussy %275)
**Research peer:** hats-e2e-engineer (ag-7aeab07b8639266a) — owns rule-list research
**Reports to:** hats-lead (ag-256b34a6fa4d04e9)
**Spawned:** 2026-04-21 by praetor directive; scope coordinated with hats-lead brief
**Constitution:** v5.1.0 / 485f4a00
**Working tree:** `/home/tanwa/hats` (shared with 3 other hats engineers — staging hygiene applies)

---

## 1. Problem statement

Three distinct coding-agent surfaces now read per-project markdown guidance:

| Agent | File read | Walk behavior | Model |
|---|---|---|---|
| claude-code (native) | `CLAUDE.md` | hierarchical up-walk to `~/.claude/CLAUDE.md` | Claude 4.x (Anthropic) |
| claude-code via Kimi wrapper (Anthropic-compat endpoint) | `CLAUDE.md` | same up-walk | **Kimi K2.5** (Moonshot) |
| codex CLI (native + codex-kimi wrapper) | `AGENTS.md` | hierarchical up-walk (OpenCode/Aider/Cursor convention) | GPT-class or Kimi K2.5 via OpenAI-compat |

Three failure modes follow:

1. **AGENTS.md drift from CLAUDE.md** — maintainer updates CLAUDE.md, forgets AGENTS.md. Codex-users read stale guidance. Observed in 16 paired-file repos on `/home/tanwa/` as of the fleet survey below.
2. **Claude-Code-CLI-specific content leaks into AGENTS.md** — e.g. "use the Task tool with subagent_type=qa-tester", "hooks fire on PostToolUse", "see ~/.claude/settings.json". Codex has no Task tool, no hooks, no `~/.claude`. Instructions are nonsense at best, misleading at worst.
3. **Anthropic-model assumptions leak into CLAUDE.md when read by Kimi K2.5** — e.g. "Claude Opus 4.7 knowledge cutoff is January 2026", "defer to Claude's refusal judgment", references to Anthropic safety framing. K2.5 is a different model with different capabilities and training; reading Anthropic-specific self-references as ground truth is a model-grounding bug.

hats sits well-positioned to catch all three because it is the single tool that already knows which provider (claude / codex / kimi / codex-kimi) a given credential slot targets.

---

## 2. Scope & non-goals

### In scope
- **Lint** `AGENTS.md` (strict — err on claude-cli leakage) and `CLAUDE.md` (warn-only when destined for Kimi K2.5 via the Anthropic-compat wrapper).
- **Sync-check** — detect drift between a paired `CLAUDE.md` / `AGENTS.md` and surface a diff.
- **Rule-list as data** — regex patterns in versioned YAML/JSON so maintainers can update rules without touching bash.
- **Per-project integration** with `hats verify` (deep-check already lints token semantics; fits with lint philosophy).
- **Fleet-sweep design** — define the read-only backfill shape (`hats sync-check --all`) for v1.1 without making it MVP.

### Explicit non-goals (for MVP)
- **Auto-fix / auto-rewrite** — rule-set confidence is too low. Surface findings; maintainer decides.
- **Generator mode** (produce AGENTS.md from CLAUDE.md). Deferred until lint rule-set is mature — see §4.
- **Non-hats fleet tooling** — we do not install lint hooks into every repo. hats is invoked manually or by CI on a per-repo basis.
- **Covering every possible future agent harness** — seed rules target codex, kimi, claude. opencode/aider/cursor are sketched for future-proofing but are nice-to-have.

---

## 3. (a) Seed rule-list — taxonomy + examples

### Four-bucket taxonomy

Agreed with hats-e2e-engineer 2026-04-21 (msg-adca3b2215e4fbe6). Splitting "Anthropic content is bad in AGENTS.md" from "Anthropic-model-self-reference is bad when Kimi K2.5 reads CLAUDE.md" gives cleaner rule targeting.

| Category | Meaning | In AGENTS.md (codex) | In CLAUDE.md-for-Kimi |
|---|---|---|---|
| **neutral** | Provider-agnostic (build commands, architecture, workflow) | MIRROR (safe) | MIRROR (safe) |
| **strip-from-agents** | Claude-Code-CLI feature reference (Task tool, hooks, slash commands, `~/.claude`) | **err** — strip | allow |
| **strip-from-claude-kimi** | Anthropic-specific framing / SDK refs that mislead K2.5 (e.g. "Anthropic SDK", "Claude's refusal judgment") | **err** — strip | **warn** when wrapper=kimi |
| **anthropic-model-assumption** | Model-name refs / model-specific capability claims (`claude-opus-4-7`, "Claude's knowledge cutoff is...") | **err** — strip | **warn** when wrapper=kimi |

### Rule-list schema (agreed with hats-e2e-engineer 2026-04-21)

```json
{
  "provider": "codex",              // codex | kimi | opencode | aider | cursor | claude
  "source_url": "https://github.com/openai/codex/blob/main/README.md",
  "schema_version": "1",
  "patterns": [
    {
      "id": "CLAUDE-CLI-001",
      "regex": "(^|[^a-zA-Z])(subagent_type|Task tool)([^a-zA-Z]|$)",
      "severity": "err",
      "category": "strip-from-agents",
      "rationale": "Task tool is a claude-code-specific mechanism; codex has no analog.",
      "citation": "claude-code docs (internal); codex CLI has `codex exec` subprocess but no tool-calling subagent primitive.",
      "action": "strip"
    },
    {
      "id": "ANTHROPIC-MODEL-001",
      "regex": "(Claude (Opus|Sonnet|Haiku)|claude-opus-4|claude-sonnet-4|claude-haiku)",
      "severity": "warn",
      "category": "anthropic-model-assumption",
      "rationale": "Model self-reference binds Kimi K2.5 readers to false ground-truth about identity/capability.",
      "citation": "reference_kimi_third_party_agent_contract.md — Kimi K2.5 reads CLAUDE.md via Anthropic-compat wrapper.",
      "action": "warn"
    }
  ]
}
```

Rule files are loaded via `jq` (already a hats dep — confirmed with hats-e2e-engineer msg-adca3b2215e4fbe6; no new dep added) from `docs/provider-rules/<provider>.json`. Current seed files landed in commit `b491ddb`: [codex.json](/home/tanwa/hats/docs/provider-rules/codex.json) and [kimi.json](/home/tanwa/hats/docs/provider-rules/kimi.json).

### Exact seed rules now in tree

**provider-neutral (mirror category):**
- No active regexes in MVP by design. This bucket is the keep/mirror set, not the reject set.
- Safe examples: build commands (`uv run`, `npm`, `cargo`), architecture notes, deployment/runbook links, issue-tracker references, code conventions.

**Claude Code CLI features to strip from `AGENTS.md` (codex reader):**
- `CLAUDE-CLI-001`
  Regex: `(^|[^A-Za-z_-])(subagent_type|Task tool)([^A-Za-z_-]|$)`
  Rationale: codex has no Claude-style Task tool or `subagent_type` primitive; these instructions are actionable-wrong.
- `CLAUDE-CLI-002`
  Regex: `(^|[^A-Za-z_-])slash commands?([^A-Za-z_-]|$)`
  Rationale: `slash command` is Claude Code vocabulary. codex uses CLI subcommands, not in-chat slash commands. Warn only because the phrase can appear generically.
- `CLAUDE-CLI-003`
  Regex: `(^|[^A-Za-z_-])(PostToolUse|PreToolUse|SessionStart|UserPromptSubmit)(Hook)?([^A-Za-z_-]|$)`
  Rationale: hook event names are Claude Code-specific and have no codex CLI analog.
- `CLAUDE-CLI-004`
  Regex: `(^|[^A-Za-z_-])claude\.ai/code([^A-Za-z_-]|$)`
  Rationale: hard Claude product URL; useless to a codex-bound agent.
- `CLAUDE-CLI-005`
  Regex: `(^|[^A-Za-z_-])(CLAUDE_CONFIG_DIR|CLAUDE_PROJECT_DIR|CLAUDE_CODE_[A-Z_]+|~/\.claude(/|$))`
  Rationale: `CLAUDE_*` vars and `~/.claude` path anchor instructions to Claude Code config, not codex (`$CODEX_HOME` / `~/.codex`).
- `CLAUDE-CLI-006`
  Regex: `(^|[^A-Za-z_-])(TaskCreate|TaskUpdate|TaskList|TaskGet|TaskOutput|TaskStop|TeamCreate|TeamDelete|teammateMode|CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS)([^A-Za-z_-]|$)`
  Rationale: Claude task/team API names would not resolve in codex.
- `CLAUDE-CLI-007`
  Regex: `(^|[^A-Za-z_-])claude-code([^A-Za-z_-]|$)`
  Rationale: explicit product-name pinning is usually leakage; warn unless the text is clearly conditional.
- `CLAUDE-CLI-008`
  Regex: `(^|[^A-Za-z_-])Skill tool([(]|[^A-Za-z_-]|$)`
  Rationale: "Skill tool" is Claude Code surface vocabulary, not codex skills dispatch.
- `CLAUDE-CLI-009`
  Regex: `(^|[^A-Za-z_-])(Explore|Plan) (agent|subagent)([^A-Za-z_-]|$)`
  Rationale: Claude built-in subagent names; codex Agent SDK primitives are user-defined.

**Anthropic-model assumptions to strip from `AGENTS.md` and warn on `CLAUDE.md`-for-Kimi:**
- `ANTHROPIC-MODEL-001`
  Regex: `(^|[^A-Za-z_-])claude[- ](opus|sonnet|haiku)[- ]?[0-9]`
  Rationale: Anthropic model IDs are not valid codex model names and mis-ground K2.5.
- `ANTHROPIC-MODEL-002`
  Regex: `(^|[^A-Za-z_-])(knowledge cutoff|training (data )?cutoff)([^A-Za-z_-]|$)`
  Rationale: cutoff claims are model-specific and can be false when the reader is GPT-class or K2.5.
- `ANTHROPIC-MODEL-003`
  Regex: `(^|[^A-Za-z_-])(Anthropic SDK|anthropic\.Anthropic[(]|from anthropic import|ANTHROPIC_API_KEY|api\.anthropic\.com)`
  Rationale: code-level Anthropic SDK/API references are valid in some repos but should not be mistaken for reader/runtime identity. Warn-only.
- `ANTHROPIC-MODEL-004`
  Regex: `(^|[^A-Za-z_-])(opus-4-7|sonnet-4-6|haiku-4-5)([^A-Za-z_-]|$)`
  Rationale: shorthand Anthropic model versions without the `claude-` prefix still misroute or mis-ground readers.
- `ANTHROPIC-MODEL-005`
  Regex: `(^|[^A-Za-z_-])(ANTHROPIC_API_KEY|ANTHROPIC_BASE_URL|ANTHROPIC_AUTH_TOKEN)([^A-Za-z_-]|$)`
  Rationale: these env vars are Claude/Kimi-wrapper auth controls, not codex auth controls.
- `HATS-ENV-INVARIANT-001`
  Regex: `(^|[^A-Za-z_-])export[[:space:]]+(ANTHROPIC_BASE_URL|ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|OPENAI_API_KEY|OPENAI_BASE_URL|CODEX_API_KEY)`
  Rationale: hard hats/Kimi invariant. Exporting these globally poisons later stock `claude`/`codex` invocations; this is the concrete 2026-04-20 incident guard.
- `KIMI-URL-001`
  Regex: `api\.moonshot\.ai/anthropic`
  Rationale: stale Kimi endpoint. Correct coding-agent endpoint is `https://api.kimi.com/coding/`.
- `ANTHROPIC-IDENTITY-001`
  Regex: `(^|[^A-Za-z_-])(You are Claude|I am Claude|As Claude)([^A-Za-z_-]|,|\.)`
  Rationale: warns when `CLAUDE.md` text depends on literal Claude identity while being read by K2.5.
- `ANTHROPIC-IDENTITY-002`
  Regex: `(Anthropic'?s?[[:space:]]+(safety|usage|HHH|training|refusal)|defer to (Claude|Anthropic))`
  Rationale: Anthropic-specific policy framing does not map cleanly onto Moonshot K2.5 behavior; useful warning, not a hard error.

**Important design correction from peer research:**
- Earlier sketch `CLAUDE-CLI-007 = MCP__...` was dropped. hats-codex-engineer confirmed codex relay-mesh MCP parity, so MCP tool-name references are not inherently codex-incompatible.

**Regex discipline** (per memory `feedback_bsd_gnu_shell_portability.md`):
- POSIX ERE only. No `\d`, `\w`, `\s`, `\b`. Use explicit character classes or `(^|[^a-zA-Z])` sentinels.
- No Perl `(?:...)` non-capturing groups; POSIX ERE doesn't support.
- Test on both GNU grep (Linux) and BSD grep (macOS — CI lane already enforces, see roadmap #9).

---

## 4. (b) Maintenance workflow — lint-only vs generator

**Recommendation: lint-only for MVP. No generator mode.**

### Maintainer workflow (recommended)

1. Maintainer authors `CLAUDE.md` as usual.
2. Maintainer manually authors `AGENTS.md` (typically shorter — build commands + workflow, minus Claude-specific tooling).
3. Before commit: `hats lint AGENTS.md --provider=codex` flags any rule-set hit at err severity. Commit blocked on err.
4. Optionally: `hats sync-check .` shows semantic drift between the two files (sections present in one but not the other).
5. Kimi-read repos also run `hats lint CLAUDE.md --provider=kimi` — warn-only; does not block commit.

### Why not generator mode

- **Risk of silent override.** Generator regenerates AGENTS.md from CLAUDE.md on every save. Maintainer's manual edits to AGENTS.md are lost on next run. Either we burn a sentinel/boundary marker (fragile) or we run a merge algorithm (hard). Neither matches hats' existing simplicity budget.
- **Rule-set confidence is the bottleneck, not tooling.** A generator that strips rule-flagged content from CLAUDE.md is exactly the lint rule-set applied destructively. Build lint first; earn confidence in the rules; THEN consider generator.
- **Current fleet state (16 pairs) already has hand-authored AGENTS.md** — they are shorter and more workflow-focused than CLAUDE.md, not mechanical strips. A generator would regress that.
- **hats-code reality.** hats is 130KB of bash. A generator that understands markdown structure, regex edits, and boundary markers is a meaningful complexity leap. Lint is ~300-line `grep -E` loop per rule.

If operator wants generator mode later: implement as `hats sync --apply` that takes the diff from `hats sync-check` and performs ONLY the additions (never deletions from AGENTS.md). That's a safe subset of generator semantics.

---

## 5. (c) Integration with hats verify + hats doctor

### hats verify — new surface
Add `--lint` flag. Off by default (verify is already a slow deep-check; don't pile on).

```bash
hats verify --lint             # check current repo's CLAUDE.md/AGENTS.md against rule-set
```

Behavior: read-only, prints rule hits grouped by file + severity. Exit 1 if any err-severity hit. Fits with verify's existing "deep semantic check" philosophy (vs doctor's layout checks).

Deferred to v1.1: `hats verify --lint --all` fleet sweep once the rule-set has earned trust.

### hats doctor — no change for MVP
doctor is layout-focused (files present, perms, symlinks). Lint is semantic. Keeping them separate preserves the doctor/verify split we established in roadmap #3.

Future: if maintainers complain about forgetting `hats verify --lint`, add a `hats doctor --with-lint` flag. Not MVP.

### New standalone surface

```bash
hats lint <file> --provider=<codex|kimi|claude>
hats sync-check [<dir>]        # diff CLAUDE.md ↔ AGENTS.md in dir (defaults to .)
```

`hats lint` is a thin wrapper that loads `docs/provider-rules/<provider>.json` and runs each regex. `hats sync-check` is a `diff`-style section-level comparator (plan: extract level-2 headings, compare set membership, then compare body within matching sections).

Deferred to v1.1: `hats sync-check --all` fleet sweep. Planned implementation should stay provider-agnostic and avoid new `case "$CURRENT_PROVIDER"` branches so `scripts/hats-fleet-symmetry-check` remains green.

---

## 6. (d) Fleet backfill question

**Fleet state as of 2026-04-21 (from survey under `/home/tanwa/`):**
- CLAUDE.md files: 96 (depth ≤ 5)
- AGENTS.md files: 38 (depth ≤ 5)
- Paired (same dir has both): 16

### Scope decision: fleet backfill is **v1.1, NOT MVP**

Per hats-lead directive (msg-c7f4116346f77eb4 2026-04-21): "fleet backfill is the scariest item — treat as LATER-PHASE; design doc should scope the minimum-viable baseline (just lint + sync-check for a single project) first; backfill is a v1.1."

### MVP scope (revised)
- `hats lint <file> --provider=<p>` on a **single file**
- `hats sync-check [<dir>]` on a **single directory** (defaults to `.`)
- `hats verify --lint` integration on the **current repo only**

No `--all` flag, no fleet sweep, no drift baseline report in MVP.

### v1.1 deferred — fleet sweep
Once MVP rule-set has weeks of real use on hats + 2-3 other repos and false-positive rate is known, revisit. Proposed shape for v1.1:

- `hats sync-check --all` — read-only sweep under configurable root (default `$HOME`)
- Fleet-drift report at `hats/docs/fleet-drift-baseline-YYYY-MM-DD.md`
- Operator-triaged cleanup — hats does not touch fleet repos unilaterally (§9 cross-project action applies)

The 16 paired repos on `/home/tanwa` aren't going anywhere; baseline them later, after the rule-set has earned trust.

---

## 7. (e) Coordination seam with hats-e2e-engineer

hats-e2e-engineer (ag-7aeab07b8639266a) owns rule-list research. Their deliverables feed §3 of this doc:

1. **Research** codex AGENTS.md upstream spec, OpenCode/Aider/Cursor conventions, Kimi K2.5 incompatibilities.
2. **Populate** `hats/docs/provider-rules/{codex,kimi,opencode,aider,cursor,claude}.json` with ~5-15 rules per provider at seed-list quality (high-confidence, well-cited).
3. **Schema agreed** 2026-04-21 via msg-26ed2c7303be5631 — see §3 above.
4. **Priority sequence** (agreed): codex first, kimi second, claude-baseline third, opencode/aider/cursor last.

I own the lint/sync-check engine that consumes their rule files. Zero file-write conflicts: they edit `docs/provider-rules/`, I edit `hats` + `tests/`.

**Handshake contract:** when hats-e2e-engineer publishes a rule file, they send a `send_to ag-1016b6fbf869d5c2` notification with file path + rule count. I wire it into the lint dispatch and run the test suite. If a regex fails BSD-compat, I push back with a POSIX-ERE-compat rewrite suggestion.

---

## 8. Ship plan (POST-SIGNOFF)

Per the brief + CLAUDE.md §4 Incremental Development: decompose into components, <30 min each.

| # | Component | Surface | Depends on | Phase |
|---|---|---|---|---|
| C1 | rule-file loader (`_load_provider_rules <provider>` — validates schema, emits patterns via `jq`) | internal | rule-list format lock-in | MVP |
| C2 | `hats lint <file> --provider=<p>` subcommand | CLI | C1 | MVP |
| C3 | codex provider-rules file (5-10 strip-from-agents rules) — hats-e2e-engineer delivers | data | — | MVP |
| C4 | kimi provider-rules file (3-5 anthropic-model-assumption rules) — hats-e2e-engineer delivers | data | — | MVP |
| C5 | `hats sync-check [<dir>]` section-level diff (single dir) | CLI | — | MVP |
| C6 | `hats verify --lint` integration (current repo only) | existing surface | C2 | MVP |
| C7 | smoke tests: lint-err-blocks, lint-warn-doesn't-block, sync-check-finds-drift, rule-file-bad-schema-fails-fast | tests | C1-C6 | MVP |
| C8 | README + roadmap entry (v1.1 scope: fleet sweep deferred) | docs | C1-C7 | MVP |
| — | `--all` fleet-sweep variants + drift-baseline report | CLI | post-MVP | **v1.1** |

QA gate: each component QA'd via `tests/smoke.sh` additions before proceeding. Fleet-symmetry-check must stay green at every component.

**Reliability-class** per memory `feedback_fleet_symmetric_improvement.md`: lint is a surface that must be symmetric across providers (`hats lint --provider=codex` and `hats lint --provider=kimi` both work). A single-provider implementation would violate the symmetric-improvement rule.

---

## 9. Open questions for operator + praetor read-pass

**Q1. Rule-file format — RESOLVED.**
JSON. Agreed with hats-e2e-engineer 2026-04-21 (msg-adca3b2215e4fbe6). Loader uses `jq` (already a hats dep — no new dep added). Kept in the open-questions list so operator can object during read-pass if they want YAML for any reason.

**Q2. hats doctor integration scope — RESOLVED.**
No change for MVP (lint lives in verify). hats-lead confirmed 2026-04-21 (msg-d358e98754c97579): doctor's layout-vs-semantic identity was hard-earned in roadmap #3; blurring it regresses. `--with-lint` flag is post-MVP if operator asks.

**Q3. Fleet-sweep cadence — RESOLVED (deferred).**
Fleet sweep is v1.1 per hats-lead directive (msg-c7f4116346f77eb4). Cadence question revisits when v1.1 scope opens. MVP does not touch fleet state.

**Q4. Anthropic-model-assumption aggressiveness — RESOLVED.**
Conservative (model-ID + capability-specific only). hats-lead confirmed 2026-04-21: over-warning devalues the signal. hats-e2e-engineer owns rule density; I own engine correctness. Clean boundary.

**Q5. Install default — RESOLVED (opt-in).**
MVP is opt-in. hats-lead confirmed 2026-04-21: don't surprise existing users with new noise on upgrade. One-line toggle if operator wants it on-by-default for new installs later.

**Q6. Fleet backfill priority — RESOLVED (v1.1).**
Deferred. MVP proves the rule-set; v1.1 triages the fleet. No operator decision needed now.

---

## 10. Non-claims / explicit risks

- **This doc is opinionated but not final.** §6 deliverables reshape on operator feedback.
- **Rule-set quality is the critical path** — a bad regex is worse than no regex. hats-e2e-engineer's research horizon (~hours) is the bottleneck, not my lint-engine (~half-day).
- **This design assumes claude-code and codex CLIs do not evolve out of AGENTS.md/CLAUDE.md convention.** If either switches to a new file format, rule-set needs a major version bump. schema_version field in rule-list anticipates this.
- **No silent auto-fix.** Ever. Even in generator mode if it lands. Maintainer always sees what hats is about to do and approves.

---

*End of design doc. Propose-and-proceed posture per §14 + §6: awaiting operator + praetor read-pass. Silence past a reasonable window = consent to proceed to C1.*
