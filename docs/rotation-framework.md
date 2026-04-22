# Credential Rotation Framework — design doc

**Status:** DRAFT — propose-and-proceed per internal-architecture authority rule (`feedback_no_operator_approval_on_internal_architecture`). Ship-gate open at hats-lead's discretion; praetor kept informed via roll-up ship-signals.

**Author:** hats-lead (ag-256b34a6fa4d04e9, debussy)
**Dispatch:** praetor msg-84fbbe5bd2f9a679 (2026-04-21 05:13Z) — supersedes B-19 standalone flip dispatch
**Amendment candidates:** B-19 (platform-throttle resiliency), B-20 (trust-tier kimi exclusion), B-21 (praetor-resilience), B-22 (rotation principles) — all drafting with praetor-lessons
**Working tree:** /home/tanwa/hats (shared with 4 peer engineers; serialization discipline per `feedback_shared_worktree_serialization.md` applies)

---

## 1. Problem statement

The mesh has accumulated multiple harnesses (claude-code, codex, claude-code-via-kimi-anthropic-compat, codex-via-kimi-openai-compat) × multiple credential pools (shannon/monet/debussy/kimi/scb10x-astartes/tanwa-slaanesh) × multiple trust tiers (ops/security vs content/research). Cross-cutting events that should trigger credential rotation have proliferated:

| Trigger class | Current handling | Failure mode |
|---|---|---|
| User quota 5h session cap | Operator manually swaps via Recipe-E | Operator bottleneck on busy surges |
| User quota weekly wall | Operator manual + Recipe-E + pray | Dead panes until reset |
| Platform throttle (Anthropic server-side 429) | Ad-hoc; sometimes recovers, sometimes not | Cascading degradation, no audit trail |
| Manual operator swap | Recipe-E skill | Works but operator-driven |
| Security incident (leaked key, compromised cred) | Not systematized | No policy, no refusal mechanism |
| Dead-man-switch (praetor/comms silent >Nmin) | No automation | Single-point-of-failure |

Each trigger has 1-N valid actions (rotate-within-harness, flip-cross-harness, respawn-preserve-identity, pause, manual-escalate) gated by trust-tier policy (ops roles can't flip to kimi). The current "shell out to Recipe-E + mesh-agent-spawn" pattern scales linearly with trigger × action combinations and can't enforce policy consistently.

This doc proposes a **decision-engine-as-data** architecture: a pure function `(fleet_state, agent, trigger) → (action, cited_rule, rollback_plan)`, with the policy matrix stored as YAML so it's auditable + updatable without code changes.

---

## 2. Scope

### In scope
- New module `hats/rotation/` with `decision.py` + `config.yaml`.
- B-19 flip helper (`hats flip <agent> --to <harness>`) as the first executable slice (PR-1).
- Trust-tier enforcement filter (B-20) as a hard gate on action selection.
- Event emission schema to praetor-comms-engineer's Slack gate.
- Rollback-plan recording for every rotation, ≤5min SLO.
- Harness-first-class CLI migration (`hats init <label>` replaces `hats codex kimi init`), with shell-alias backcompat.
- Integration surface for quota_watchdog (agent-ops task #40) + dead-man-switch (task #41) to emit triggers the engine consumes.

### Non-goals (explicit)
- Replacing Recipe-E/Recipe-F/Recipe-G (those become actions the engine dispatches to, not entities it supersedes).
- Auto-provisioning new Anthropic/codex/kimi accounts. Framework assumes accounts are pre-existing.
- Cross-machine rotation (multi-host failover). Single-workstation only for v1.
- Auto-response to security incidents beyond refusal + escalation. Actual remediation stays operator-driven.
- ML/heuristic-driven action selection. Deterministic rule matching only.

---

## 3. Architecture

### 3.1 Data model (hats/rotation/config.yaml)

```yaml
schema_version: 1

# Harness catalog — defines execution contexts.
harnesses:
  claude-code:
    command: claude
    config_dir_env: CLAUDE_CONFIG_DIR
    quota_resets: {session_5h: 5h, weekly: 7d}
    mcp_config_surface: per_account
  codex:
    command: codex
    config_dir_env: CODEX_HOME
    quota_resets: {session_5h: null, weekly: 7d, daily: 24h}
    mcp_config_surface: user_global
  claude-via-kimi-anthropic:
    command: claude  # same binary, different env-inline shape
    config_dir_env: CLAUDE_CONFIG_DIR
    quota_resets: {usage_based: null}  # Moonshot = usage-billed, no session cap
    mcp_config_surface: per_account
    parent_harness: claude-code
  codex-via-kimi-openai:
    command: codex
    config_dir_env: CODEX_HOME
    quota_resets: {usage_based: null}
    mcp_config_surface: user_global
    parent_harness: codex

# Provider catalog — who owns the tokens.
providers:
  anthropic:
    quota_model: tiered_subscription
    auth_flow: oauth
    status_probe: platform.claude.com/health  # or equivalent
  openai:
    quota_model: api_pay_per_use
    auth_flow: chatgpt_oauth | api_key
  moonshot:
    quota_model: api_pay_per_use
    auth_flow: api_key

# Account catalog — each row is a (label, harness, provider) triple.
accounts:
  - label: shannon
    harness: claude-code
    provider: anthropic
    trust_tier: ops
    quota_model: max
    current_state: active
  - label: monet
    harness: claude-code
    provider: anthropic
    trust_tier: ops
    quota_model: max
    current_state: quota_hit  # e.g. weekly, resets 2026-04-24 02:00 BKK
  - label: debussy
    harness: claude-code
    provider: anthropic
    trust_tier: ops
    quota_model: max
    current_state: active
  - label: kimi
    harness: claude-via-kimi-anthropic
    provider: moonshot
    trust_tier: content  # explicit kimi-exclusion-from-ops per B-20
    quota_model: api_pay_per_use
    current_state: active
  - label: astartes  # renamed from tanwa 2026-04-21
    harness: codex
    provider: openai
    trust_tier: ops
    quota_model: chatgpt_subscription
    current_state: active
  - label: slaanesh  # renamed from scb10x 2026-04-21
    harness: codex
    provider: openai
    trust_tier: ops
    quota_model: chatgpt_subscription
    current_state: active

# Trust tiers — symbolic levels with policy.
trust_tiers:
  ops:
    description: "Server admin, Infisical, SSH/sudo, secrets-handling roles"
    allowed_accounts: [shannon, monet, debussy, astartes, slaanesh]
    # kimi excluded per B-20
  content:
    description: "Content authoring, research, canary, low-risk"
    allowed_accounts: [shannon, monet, debussy, astartes, slaanesh, kimi]

# Role → trust-tier map (agent name patterns).
role_trust_map:
  - pattern: "^(praetor|praetor-.*|hats-lead|hats-.*-engineer|dominion-.*|agent-ops|.*-infra)$"
    tier: ops
  - pattern: "^(lumilingua-.*|.*-content.*|.*-canary|.*-research)$"
    tier: content
  - pattern: ".*"  # default
    tier: content  # safe default; err toward permissive for canaries

# Triggers — events that enter the engine.
triggers:
  user_quota_5h:
    detected_by: session_cap_banner | 429_throttle_burst
    urgency: normal
  user_quota_weekly:
    detected_by: weekly_limit_banner
    urgency: high
  user_quota_daily:
    detected_by: daily_limit_banner
    urgency: normal
  platform_throttle:
    detected_by: persistent_429_post_cooldown | server_temporarily_limiting_banner
    urgency: high
  manual:
    detected_by: hats_flip_cli
    urgency: normal
  security_incident:
    detected_by: operator_signal | key_leak_detector
    urgency: urgent
  dead_man:
    detected_by: heartbeat_missed_3x
    urgency: urgent

# Decision table — rows matched top-to-bottom, first match wins.
# Columns: trigger, from_state, role_tier, default_action, fallback_action, note
decisions:
  - trigger: user_quota_5h
    from_trust_tier: "*"
    action: rotate_within_harness
    fallback: pause_not_respawn
    note: "Session cap typically resets in ~1h; prefer rotate + retry later"

  - trigger: user_quota_weekly
    from_trust_tier: ops
    action: flip_cross_harness
    target_harness_priority: [codex, claude-code]  # kimi excluded per B-20
    fallback: manual_escalate
    note: "Weekly wall is hard; flip to codex-astartes or remaining-healthy claude cred"

  - trigger: user_quota_weekly
    from_trust_tier: content
    action: flip_cross_harness
    target_harness_priority: [codex, claude-via-kimi-anthropic, claude-code]
    fallback: manual_escalate

  - trigger: platform_throttle
    from_trust_tier: ops
    action: flip_cross_harness
    target_harness_priority: [codex]
    fallback: pause_not_respawn
    note: "Ops can only go codex when platform_throttle; kimi-excluded"

  - trigger: platform_throttle
    from_trust_tier: content
    action: flip_cross_harness
    target_harness_priority: [codex, claude-via-kimi-anthropic]
    fallback: pause_not_respawn

  - trigger: manual
    from_trust_tier: "*"
    action: flip_cross_harness
    target_harness: from_cli_arg
    fallback: refuse
    note: "Operator specifies target; trust-tier filter still applies"

  - trigger: security_incident
    from_trust_tier: "*"
    action: pause_not_respawn
    note: "Never auto-rotate on security; operator must investigate"

  - trigger: dead_man
    from_role: "^(praetor|praetor-comms-engineer)$"
    from_trust_tier: ops
    action: flip_cross_harness
    target_harness: codex
    note: "B-21 praetor-resilience; auto-flip without ACK"

  - trigger: dead_man
    from_trust_tier: "*"
    action: respawn_preserve_identity  # on same harness+cred if still healthy
    fallback: manual_escalate
```

### 3.2 Decision engine (hats/rotation/decision.py)

Pure function (no I/O, no side effects). Testable with table-driven unit tests against the YAML.

```python
def decide(fleet_state: FleetState,
           agent: AgentInfo,
           trigger: Trigger,
           config: RotationConfig) -> Decision:
    """Return (action, cited_rule, rollback_plan) or raise RefusedTransition.

    fleet_state: all live agents + account current_state per the yaml.
    agent: the candidate for rotation (name, role, current_harness, current_account).
    trigger: the event (type + metadata like from_cli_target).
    config: loaded config.yaml.
    """
    tier = resolve_trust_tier(agent.name, config.role_trust_map)
    for rule in config.decisions:
        if not match(rule, trigger, agent, tier):
            continue
        action = rule.action
        if action == 'flip_cross_harness':
            target_harness = pick_target_harness(rule, fleet_state, tier, config)
            if target_harness is None:
                action = rule.fallback
        if action == 'flip_cross_harness':
            target_account = pick_target_account(target_harness, fleet_state, tier, config)
            if target_account is None:
                action = rule.fallback
            enforce_trust_tier(tier, target_account, config)  # may raise RefusedTransition
        return Decision(
            action=action,
            cited_rule=rule.id,
            target_harness=target_harness if action == 'flip_cross_harness' else None,
            target_account=target_account if action == 'flip_cross_harness' else None,
            rollback_plan=build_rollback_plan(agent, action, target_harness, target_account),
        )
    raise NoRuleMatched(trigger, agent)
```

Enforcement invariants:
- `enforce_trust_tier` is the hard gate. Any action whose target account violates the agent's trust-tier raises `RefusedTransition` with `cited_rule=<tier-rule-id>`. Caller logs + escalates.
- `pick_target_harness` respects `target_harness_priority` ordering. Skips harnesses where all accounts are `quota_hit` or `unresponsive`.
- Decision function is deterministic: same (fleet_state, agent, trigger) always produces same Decision.

### 3.3 Action dispatcher

Separate from the engine. Takes a Decision + mutates the world:

- `rotate_within_harness` → Recipe-E (same harness, different account under same provider).
- `flip_cross_harness` → B-19 flip (different harness). Includes memory rsync between `~/.hats/<from_harness>/projects/<ws>/memory/` and `~/.hats/<to_harness>/projects/<ws>/memory/`.
- `respawn_preserve_identity` → Recipe-G (same harness+account, kill+respawn the pane with §14 identity).
- `pause_not_respawn` → deregister + tmux kill-pane, no respawn. Operator intervention required.
- `manual_escalate` → send_to praetor with Decision context; no automated mutation.

Each dispatcher writes a rollback plan to `~/.hats/rotation/rollback/<event_id>.yaml` before mutating, so rollback = apply-reverse from disk.

### 3.4 Observability

Every rotation emits an event to `praetor-comms-engineer` via send_to:

```json
{
  "ts": "2026-04-21T05:20:00Z",
  "event_id": "rot-2026-04-21-05-20-00-abc123",
  "agent_name": "lumilingua-content-author",
  "agent_id_before": "ag-...",
  "agent_id_after": "ag-...",
  "from_harness": "claude-code",
  "from_account": "debussy",
  "to_harness": "claude-via-kimi-anthropic",
  "to_account": "kimi",
  "trigger": "platform_throttle",
  "decision_rule": "rule-07-content-platform-throttle",
  "outcome": "success",
  "duration_ms": 12340,
  "rollback_plan_id": "rot-2026-04-21-05-20-00-abc123"
}
```

Schema lives in `hats/rotation/events.schema.json` for machine validation at emit + consume time.

### 3.5 Rollback

Every mutating action records reverse-plan at decide-time. Plan stored at `~/.hats/rotation/rollback/<event_id>.yaml`:

```yaml
event_id: rot-2026-04-21-05-20-00-abc123
reverse_action: flip_cross_harness
target_harness: claude-code
target_account: debussy
target_pane: "%280"
restore_memory_from: "/home/tanwa/.hats/claude/debussy/projects/-home-tanwa-lumilingua/memory/live_state_pre_rotation.md"
notes: "Operator-fired rollback; target state snapshotted pre-rotation"
expires: "2026-04-22T05:20:00Z"
```

`hats rotation rollback <event_id>` re-dispatches the reverse action. SLO: ≤5min from operator invocation to restored pane + registered agent.

---

## 4. Harness-first-class CLI migration

### 4.1 New surface

```
hats init <label> [--harness <h>] [--provider <p>] [--trust-tier <t>]
hats flip <agent> --to <label> [--reason <r>] [--dry-run]
hats rotation status
hats rotation log [--since <dt>] [--agent <name>]
hats rotation rollback <event_id>
```

`hats init <label>` reads the label from `rotation/config.yaml` and invokes the right harness-specific initializer. Replaces the provider-prefix `hats codex kimi init`. Existing flows keep working via alias.

### 4.2 Shell-alias backcompat

Shell functions stay for operator convenience. `hats shell-init` emits:
- `shannon/monet/debussy "..."` (existing)
- `kimi "..."` (existing) — now formally an alias for `hats invoke --label kimi`
- `codex_astartes/codex_slaanesh "..."` (post-codex-engineer-rename) — alias for `hats invoke --label astartes/slaanesh`
- `codex_kimi "..."` — alias for `hats invoke --label kimi-codex` (once kimi-engineer's wire_api fix lands + the codex-kimi account gets registered in config.yaml)

### 4.3 Deprecation

`hats codex kimi init`, `hats codex init` stay in place with a DeprecationWarning for one minor version; removed at v1.2.

---

## 5. PR plan

### PR-1 — B-19 flip MVP (TONIGHT)

**Scope:** `hats flip <agent> --to <harness>` minimal executable path. Trust-tier rules hardcoded inline (they'll move to config.yaml in PR-2). Supports the two most-urgent target classes: claude→codex (ops-eligible per B-20) and claude→kimi-claude (content-tier only).

**Files:**
- `hats` — new `cmd_flip` subcommand + dispatcher. ~150-200 lines.
- `tests/smoke.sh` — new `test_flip_claude_to_codex_trust_tier_gate`, `test_flip_refuses_ops_to_kimi`, `test_flip_idempotent_round_trip`.
- `docs/rotation-framework.md` — this doc, committed for audit.

**Ship criteria:**
- Trust-tier filter rejects ops→kimi with `refused reason=trust-tier-policy-B-20`.
- Memory rsync correctly spans `~/.hats/<from>/projects/<ws>/memory/` → `~/.hats/<to>/projects/<ws>/memory/`.
- Rollback plan written to `~/.hats/rotation/rollback/<event_id>.yaml` before mutation.
- Praetor dead-man test: simulate praetor claude→codex flip, confirm `codex_astartes` spawn registers with preserved §14 identity within 120s.
- Smoke + fleet-symmetry stay green.

**Time-box:** 2-3h after queue drain (mirror-engineer + e2e-engineer ship first).

### PR-2 — rotation framework core (NEXT 24H)

**Scope:** extract hardcoded trust-tier rules from PR-1 into config.yaml + decision.py. Add event emission to praetor-comms-engineer. Add `hats rotation {status,log,rollback}` subcommands.

**Files:**
- `hats/rotation/config.yaml` — canonical account + trust-tier + decision-table schema.
- `hats/rotation/decision.py` — pure decision function + unit tests.
- `hats/rotation/events.schema.json` — event validator.
- `hats/rotation/dispatcher.py` — action → world-mutation.
- `hats` — `cmd_flip` rewired to consume decision.py; new `cmd_rotation` subcommand.

**Ship criteria:**
- 100% of trust-tier decisions go through config.yaml; no Python-embedded tier checks.
- Table-driven unit tests cover (trigger × tier × fleet_state) cartesian for the interesting cells.
- Event schema validated at emit + received by praetor-comms-engineer Slack gate.
- Rollback CLI round-trip tested end-to-end.

**Time-box:** 3-4h over next 24h.

### PR-3 — harness-first-class CLI (24-48H AFTER PR-2)

**Scope:** `hats init <label>` primary; deprecate `hats codex <x>` prefix paths. quota_watchdog (agent-ops) rewired to emit structured triggers.

**Files:**
- `hats` — `cmd_init` refactor to dispatch via config.yaml label.
- Agent-ops coordination for quota_watchdog emitter.
- Operator-facing UX pre-announce via praetor (ship-gate rule).

**Time-box:** 2-3h, conditional on PR-2 stability.

---

## 6. Test matrix

**PR-1:**
- `flip praetor --to codex` → succeeds; new praetor-codex takes over Slack dispatch + fetches queued messages.
- `flip praetor --to kimi` → refused; cited_rule=trust-tier-B-20.
- `flip lumilingua-content-author --to kimi` → succeeds.
- Round-trip: `flip A --to kimi` → `flip A --to claude-code` → same name preserved, new agent_ids, memory carried.
- Target-quota-hit: simulate all-codex-quota-hit, `flip praetor --to codex` refuses with cited_rule=no-target-available.
- Mid-dispatch: flip praetor while praetor is sending to 5 agents → no dropped messages (praetor-comms-engineer handles delivery, flip preserves its send_to queue).

**PR-2:**
- Property tests on decision.py: any (trigger × tier × fleet_state) resolves deterministically or refuses.
- Event emission: every rotation produces a valid event per schema; praetor-comms-engineer acks.
- Rollback: `hats rotation rollback <event_id>` within 5min restores pre-rotation state.

**PR-3:**
- `hats init <label>` matches existing `hats codex kimi init` output for same account.
- Deprecation warning fires on old surface.
- quota_watchdog emits triggers the engine consumes.

---

## 7. Risks

- **YAML schema evolution** — adding a new action/trigger requires updating the schema + every decision row. Mitigation: `schema_version` field + migration shim at load time.
- **Trust-tier coverage gaps** — role_trust_map pattern-matches agent names; an unnamed class could default to `content` when it should be `ops`. Mitigation: default-deny harden → require explicit tier for unknown roles (fallback to `ops` not `content`). Revisit after 1 week of production use.
- **Decision engine blast radius** — a buggy rule row could mass-flip the wrong roles. Mitigation: engine output is Decision NOT world-mutation; dispatcher consumes Decisions one-at-a-time with mandatory rollback-plan write; operator can dry-run via `--dry-run` flag.
- **Rollback plan staleness** — a stored rollback plan targeting a pane that was killed mid-session won't apply cleanly. Mitigation: rollback plans expire after 24h; dispatcher refuses to execute expired plans.

---

## 8. Coordination ownership

| Engineer | Surface | Status |
|---|---|---|
| hats-codex-engineer (ag-bfc2b02fce6e6809) | codex label rename (tanwa→astartes, scb10x→slaanesh) lands FIRST, blocks everything | GO'd 2026-04-21 05:14Z |
| hats-kimi-engineer (ag-1755a24ecbfb4a95) | P1 wire_api=chat rejection in codex-kimi; kimi OpenAI-compat nuances fold into provider metadata | Investigation started; ship after codex rename |
| hats-mirror-engineer (ag-1016b6fbf869d5c2) | AGENTS.md/CLAUDE.md reflection of new `hats init <label>` CLI surface (post-PR-3) | Slot 3 in serialization queue; lint+sync first |
| hats-e2e-engineer (ag-7aeab07b8639266a) | Test harness for rotation events + dispatcher integration + probe coverage for trust-tier filter | Slot 4 C3 retry first, then rotation-framework test fold-in |
| praetor-agent-ops | quota_watchdog consumer side — emits structured triggers into decision engine at PR-3 | Coord via praetor |
| praetor-comms-engineer | Slack-gate consumer of rotation events; schema alignment in PR-2 | msg-4376dac5e9d4fd76 thread |
| praetor-lessons | B-19/B-20/B-21/B-22 amendment ratification | Draft; ratifies after PR-1 + operator approval |

---

## 9. Open questions (non-blocking; operator or praetor input helps, not required)

- **B-22 amendment name**: "Credential rotation is deterministic, auditable, and reversible"? Praetor-lessons owns final wording.
- **quota_watchdog detection fidelity**: does agent-ops's watchdog distinguish session-cap-5h from weekly-wall reliably on banners? Affects trigger routing.
- **Label rename backcompat window**: after astartes/slaanesh lands, keep tanwa/scb10x as symlinks for how long? Recommend zero (atomic, operator re-sources shell once) per codex-engineer's read-only audit lean.
- **kimi-codex viability**: depends on kimi-engineer's wire_api P1 resolution. If (c) "disable codex-kimi", the `kimi-codex` label is removed from config.yaml entirely + trust-tier matrix collapses.

---

*End of design doc. Silence past a reasonable window from praetor = consent to proceed to PR-1 per §6.*
