#!/usr/bin/env python3
"""
Unit tests for hats rotation decision engine.

Table-driven: every (trigger x tier x fleet_state) cartesian for interesting cells.
"""

from pathlib import Path

from decision import (
    AccountState,
    AgentInfo,
    Decision,
    FleetState,
    NoRuleMatched,
    RefusedTransition,
    RotationConfig,
    Trigger,
    decide,
    load_config,
    resolve_trust_tier,
)

CONFIG_PATH = Path(__file__).with_name("config.yaml")


# ── Fixtures ────────────────────────────────────────────────────────


def _config() -> RotationConfig:
    return load_config(CONFIG_PATH)


def _fleet_all_healthy() -> FleetState:
    return FleetState(
        accounts=(
            AccountState("shannon", "claude-code", "active"),
            AccountState("monet", "claude-code", "active"),
            AccountState("debussy", "claude-code", "active"),
            AccountState("kimi", "claude-via-kimi-anthropic", "active"),
            AccountState("astartes", "codex", "active"),
            AccountState("slaanesh", "codex", "active"),
        )
    )


def _fleet_all_quota_hit() -> FleetState:
    return FleetState(
        accounts=(
            AccountState("shannon", "claude-code", "quota_hit"),
            AccountState("monet", "claude-code", "quota_hit"),
            AccountState("debussy", "claude-code", "quota_hit"),
            AccountState("kimi", "claude-via-kimi-anthropic", "quota_hit"),
            AccountState("astartes", "codex", "quota_hit"),
            AccountState("slaanesh", "codex", "quota_hit"),
        )
    )


def _fleet_codex_only_healthy() -> FleetState:
    return FleetState(
        accounts=(
            AccountState("shannon", "claude-code", "quota_hit"),
            AccountState("monet", "claude-code", "quota_hit"),
            AccountState("debussy", "claude-code", "quota_hit"),
            AccountState("kimi", "claude-via-kimi-anthropic", "quota_hit"),
            AccountState("astartes", "codex", "active"),
            AccountState("slaanesh", "codex", "active"),
        )
    )


# ── Trust tier resolution ───────────────────────────────────────────


def test_resolve_praetor_is_ops():
    cfg = _config()
    assert resolve_trust_tier("praetor", cfg.role_trust_map) == "ops"


def test_resolve_praetor_comms_is_ops():
    cfg = _config()
    assert resolve_trust_tier("praetor-comms-engineer", cfg.role_trust_map) == "ops"


def test_resolve_hats_lead_is_ops():
    cfg = _config()
    assert resolve_trust_tier("hats-lead", cfg.role_trust_map) == "ops"


def test_resolve_hats_engineer_is_ops():
    cfg = _config()
    # Pattern is hats-.*-engineer; hats-eng3 doesn't match but hats-eng3-role does
    assert resolve_trust_tier("hats-eng3-role-engineer", cfg.role_trust_map) == "ops"


def test_resolve_lumilingua_is_content():
    cfg = _config()
    assert resolve_trust_tier("lumilingua-content-author", cfg.role_trust_map) == "content"


def test_resolve_canary_is_content():
    cfg = _config()
    assert resolve_trust_tier("test-canary", cfg.role_trust_map) == "content"


def test_resolve_unknown_defaults_content():
    cfg = _config()
    assert resolve_trust_tier("random-agent", cfg.role_trust_map) == "content"


# ── User quota 5h ───────────────────────────────────────────────────


def test_quota_5h_ops_rotates_within_harness():
    cfg = _config()
    agent = AgentInfo("praetor", "praetor", "claude-code", "shannon")
    trigger = Trigger("user_quota_5h")
    d = decide(_fleet_all_healthy(), agent, trigger, cfg)
    assert d.action == "rotate_within_harness"
    assert d.target_harness is None


def test_quota_5h_content_rotates_within_harness():
    cfg = _config()
    agent = AgentInfo("lumilingua-author", "content", "claude-code", "shannon")
    trigger = Trigger("user_quota_5h")
    d = decide(_fleet_all_healthy(), agent, trigger, cfg)
    assert d.action == "rotate_within_harness"


# ── Platform throttle ───────────────────────────────────────────────


def test_platform_throttle_ops_flips_to_codex():
    cfg = _config()
    agent = AgentInfo("praetor", "praetor", "claude-code", "shannon")
    trigger = Trigger("platform_throttle")
    d = decide(_fleet_all_healthy(), agent, trigger, cfg)
    assert d.action == "flip_cross_harness"
    assert d.target_harness == "codex"
    assert d.target_account in ("astartes", "slaanesh")


def test_platform_throttle_content_flips_to_codex_or_kimi():
    cfg = _config()
    agent = AgentInfo("lumilingua-author", "content", "claude-code", "shannon")
    trigger = Trigger("platform_throttle")
    d = decide(_fleet_all_healthy(), agent, trigger, cfg)
    assert d.action == "flip_cross_harness"
    assert d.target_harness in ("codex", "claude-via-kimi-anthropic")


def test_platform_throttle_ops_no_codex_fallback_pause():
    """All codex accounts quota_hit -> fallback pause_not_respawn."""
    cfg = _config()
    agent = AgentInfo("praetor", "praetor", "claude-code", "shannon")
    trigger = Trigger("platform_throttle")
    # Only claude accounts healthy; codex all hit
    fleet = FleetState(
        accounts=(
            AccountState("shannon", "claude-code", "active"),
            AccountState("astartes", "codex", "quota_hit"),
            AccountState("slaanesh", "codex", "quota_hit"),
        )
    )
    d = decide(fleet, agent, trigger, cfg)
    assert d.action == "pause_not_respawn"


# ── Weekly quota ────────────────────────────────────────────────────


def test_weekly_quota_ops_flips_to_codex():
    cfg = _config()
    agent = AgentInfo("praetor", "praetor", "claude-code", "shannon")
    trigger = Trigger("user_quota_weekly")
    d = decide(_fleet_all_healthy(), agent, trigger, cfg)
    assert d.action == "flip_cross_harness"
    assert d.target_harness == "codex"


def test_weekly_quota_content_flips_prefers_codex():
    cfg = _config()
    agent = AgentInfo("lumilingua-author", "content", "claude-code", "shannon")
    trigger = Trigger("user_quota_weekly")
    d = decide(_fleet_all_healthy(), agent, trigger, cfg)
    assert d.action == "flip_cross_harness"
    # codex is first priority for content too
    assert d.target_harness == "codex"


def test_weekly_quota_all_hit_escalates():
    cfg = _config()
    agent = AgentInfo("praetor", "praetor", "claude-code", "shannon")
    trigger = Trigger("user_quota_weekly")
    d = decide(_fleet_all_quota_hit(), agent, trigger, cfg)
    assert d.action == "manual_escalate"


# ── Manual flip (B-19/B-20) ─────────────────────────────────────────


def test_manual_ops_to_codex_succeeds():
    cfg = _config()
    agent = AgentInfo("praetor", "praetor", "claude-code", "shannon")
    trigger = Trigger("manual", {"target_harness": "codex"})
    d = decide(_fleet_all_healthy(), agent, trigger, cfg)
    assert d.action == "flip_cross_harness"
    assert d.target_harness == "codex"


def test_manual_ops_to_kimi_refused_b20():
    """B-20: ops tier cannot use kimi."""
    cfg = _config()
    agent = AgentInfo("praetor", "praetor", "claude-code", "shannon")
    trigger = Trigger("manual", {"target_harness": "claude-via-kimi-anthropic"})
    with pytest.raises(RefusedTransition) as exc:
        decide(_fleet_all_healthy(), agent, trigger, cfg)
    assert exc.value.cited_rule == "trust-tier-policy-B-20"


def test_manual_content_to_kimi_allowed():
    """Content tier CAN use kimi."""
    cfg = _config()
    agent = AgentInfo("lumilingua-author", "content", "claude-code", "shannon")
    trigger = Trigger("manual", {"target_harness": "claude-via-kimi-anthropic"})
    d = decide(_fleet_all_healthy(), agent, trigger, cfg)
    assert d.action == "flip_cross_harness"
    assert d.target_harness == "claude-via-kimi-anthropic"
    assert d.target_account == "kimi"


# ── Security incident ───────────────────────────────────────────────


def test_security_incident_always_pause():
    cfg = _config()
    agent = AgentInfo("praetor", "praetor", "claude-code", "shannon")
    trigger = Trigger("security_incident")
    d = decide(_fleet_all_healthy(), agent, trigger, cfg)
    assert d.action == "pause_not_respawn"


def test_security_incident_content_also_pause():
    cfg = _config()
    agent = AgentInfo("lumilingua-author", "content", "claude-code", "shannon")
    trigger = Trigger("security_incident")
    d = decide(_fleet_all_healthy(), agent, trigger, cfg)
    assert d.action == "pause_not_respawn"


# ── Dead man switch ─────────────────────────────────────────────────


def test_dead_man_praetor_flips_to_codex():
    """B-21: praetor dead-man auto-flips to codex without ACK."""
    cfg = _config()
    agent = AgentInfo("praetor", "praetor", "claude-code", "shannon")
    trigger = Trigger("dead_man")
    d = decide(_fleet_all_healthy(), agent, trigger, cfg)
    assert d.action == "flip_cross_harness"
    assert d.target_harness == "codex"


def test_dead_man_praetor_comms_flips_to_codex():
    cfg = _config()
    agent = AgentInfo("praetor-comms-engineer", "praetor-comms", "claude-code", "shannon")
    trigger = Trigger("dead_man")
    d = decide(_fleet_all_healthy(), agent, trigger, cfg)
    assert d.action == "flip_cross_harness"
    assert d.target_harness == "codex"


def test_dead_man_non_praetor_respawn():
    """Non-praetor dead_man -> respawn_preserve_identity."""
    cfg = _config()
    agent = AgentInfo("lumilingua-author", "content", "claude-code", "shannon")
    trigger = Trigger("dead_man")
    d = decide(_fleet_all_healthy(), agent, trigger, cfg)
    assert d.action == "respawn_preserve_identity"


def test_dead_man_non_praetor_current_account_healthy_respawns():
    """If current account is healthy, respawn on same harness+cred."""
    cfg = _config()
    agent = AgentInfo("lumilingua-author", "content", "claude-code", "shannon")
    trigger = Trigger("dead_man")
    # shannon is active in this fleet
    fleet = FleetState(
        accounts=(
            AccountState("shannon", "claude-code", "active"),
            AccountState("monet", "claude-code", "quota_hit"),
        )
    )
    d = decide(fleet, agent, trigger, cfg)
    assert d.action == "respawn_preserve_identity"


def test_dead_man_non_praetor_current_account_unhealthy_escalates():
    """If current account is quota_hit, can't respawn — escalate."""
    cfg = _config()
    agent = AgentInfo("lumilingua-author", "content", "claude-code", "shannon")
    trigger = Trigger("dead_man")
    d = decide(_fleet_all_quota_hit(), agent, trigger, cfg)
    assert d.action == "manual_escalate"


# ── Determinism property ────────────────────────────────────────────


def test_same_input_same_output():
    """decide() is deterministic."""
    cfg = _config()
    agent = AgentInfo("praetor", "praetor", "claude-code", "shannon")
    trigger = Trigger("platform_throttle")
    fleet = _fleet_all_healthy()

    d1 = decide(fleet, agent, trigger, cfg)
    d2 = decide(fleet, agent, trigger, cfg)
    assert d1 == d2


# ── No rule matched ─────────────────────────────────────────────────


def test_unknown_trigger_raises():
    cfg = _config()
    agent = AgentInfo("praetor", "praetor", "claude-code", "shannon")
    trigger = Trigger("unknown_trigger_xyz")
    with pytest.raises(NoRuleMatched):
        decide(_fleet_all_healthy(), agent, trigger, cfg)


# ── Rollback plan ───────────────────────────────────────────────────


def test_flip_includes_rollback():
    cfg = _config()
    agent = AgentInfo("praetor", "praetor", "claude-code", "shannon")
    trigger = Trigger("platform_throttle")
    d = decide(_fleet_all_healthy(), agent, trigger, cfg)
    assert d.rollback_plan["reverse_action"] == "flip_cross_harness"
    assert d.rollback_plan["original_harness"] == "claude-code"
    assert d.rollback_plan["original_account"] == "shannon"
    assert d.rollback_plan["agent_name"] == "praetor"
    assert "target_harness" in d.rollback_plan


# ── pytest glue ─────────────────────────────────────────────────────


import pytest  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
