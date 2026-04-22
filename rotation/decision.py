#!/usr/bin/env python3
"""
hats rotation decision engine — pure function, no I/O, no side effects.

  Decision = decide(fleet_state, agent, trigger, config)

Deterministic: same (fleet_state, agent, trigger) always produces same Decision.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


# ── Exceptions ──────────────────────────────────────────────────────


class RefusedTransition(Exception):
    """Trust-tier or policy refused this transition."""

    def __init__(self, reason: str, cited_rule: str):
        self.reason = reason
        self.cited_rule = cited_rule
        super().__init__(f"Refused: {reason} (rule={cited_rule})")


class NoRuleMatched(Exception):
    """No decision rule matched the given (trigger, agent) pair."""

    def __init__(self, trigger: Trigger, agent: AgentInfo):
        self.trigger = trigger
        self.agent = agent
        super().__init__(f"No rule matched for trigger={trigger.type} agent={agent.name}")


# ── Data classes ────────────────────────────────────────────────────


@dataclass(frozen=True)
class AgentInfo:
    name: str
    role: str
    current_harness: str
    current_account: str
    agent_id: str = ""


@dataclass(frozen=True)
class Trigger:
    type: str
    metadata: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class AccountState:
    label: str
    harness: str
    current_state: str  # active | quota_hit | unresponsive


@dataclass(frozen=True)
class FleetState:
    accounts: tuple[AccountState, ...]

    def harness_accounts(self, harness: str) -> list[AccountState]:
        return [a for a in self.accounts if a.harness == harness]

    def healthy_accounts(self, harness: str) -> list[AccountState]:
        return [a for a in self.accounts if a.harness == harness and a.current_state == "active"]


@dataclass(frozen=True)
class Decision:
    action: str
    cited_rule: str
    target_harness: str | None = None
    target_account: str | None = None
    rollback_plan: dict[str, Any] = field(default_factory=dict)


@dataclass
class RotationConfig:
    schema_version: int
    harnesses: dict[str, dict]
    providers: dict[str, dict]
    accounts: list[dict]
    trust_tiers: dict[str, dict]
    role_trust_map: list[dict]
    triggers: dict[str, dict]
    decisions: list[dict]

    @classmethod
    def from_dict(cls, d: dict) -> RotationConfig:
        return cls(
            schema_version=d.get("schema_version", 1),
            harnesses=d.get("harnesses", {}),
            providers=d.get("providers", {}),
            accounts=d.get("accounts", []),
            trust_tiers=d.get("trust_tiers", {}),
            role_trust_map=d.get("role_trust_map", []),
            triggers=d.get("triggers", {}),
            decisions=d.get("decisions", []),
        )


# ── Pure functions ──────────────────────────────────────────────────


def resolve_trust_tier(agent_name: str, role_trust_map: list[dict]) -> str:
    """Return the trust tier for an agent by matching role patterns."""
    for entry in role_trust_map:
        pattern = entry.get("pattern", ".*")
        if re.search(pattern, agent_name):
            return entry.get("tier", "content")
    return "content"


def _match_rule(rule: dict, trigger: Trigger, agent: AgentInfo, tier: str) -> bool:
    """Check if a decision rule matches the given context."""
    # Trigger type match
    if rule.get("trigger") != trigger.type:
        return False

    # Trust tier match
    rule_tier = rule.get("from_trust_tier", "*")
    if rule_tier != "*" and rule_tier != tier:
        return False

    # Role pattern match (optional)
    rule_role = rule.get("from_role")
    if rule_role is not None:
        if not re.search(rule_role, agent.name):
            return False

    return True


def _pick_target_harness(
    rule: dict,
    fleet_state: FleetState,
    tier: str,
    config: RotationConfig,
) -> str | None:
    """Select the best target harness per the rule's priority list."""
    # Explicit target harness from CLI or rule
    target = rule.get("target_harness")
    if target == "from_cli_arg":
        # Caller must provide this in trigger metadata
        return None
    if target is not None:
        return target

    # Priority-ordered list
    priority = rule.get("target_harness_priority", [])
    for harness in priority:
        healthy = fleet_state.healthy_accounts(harness)
        if healthy:
            return harness

    return None


def _pick_target_account(
    harness: str,
    fleet_state: FleetState,
    tier: str,
    config: RotationConfig,
) -> str | None:
    """Select the best account within a target harness.

    Does NOT filter by trust tier — enforcement happens separately via
    enforce_trust_tier so that violations raise RefusedTransition with
    a clear cited_rule (B-20 etc) rather than silently falling back.
    """
    healthy = fleet_state.healthy_accounts(harness)
    if not healthy:
        return None

    # Prefer first healthy candidate (load-balancing can be added later)
    return healthy[0].label


def enforce_trust_tier(
    tier: str,
    target_account: str,
    config: RotationConfig,
) -> None:
    """Raise RefusedTransition if target_account violates tier policy."""
    allowed = set()
    for tier_name, tier_data in config.trust_tiers.items():
        if tier_name == tier:
            allowed = set(tier_data.get("allowed_accounts", []))
            break

    if target_account not in allowed:
        # B-20: kimi is explicitly excluded from ops tier
        cited = "trust-tier-policy-B-20" if target_account == "kimi" and tier == "ops" else "trust-tier-policy"
        raise RefusedTransition(
            reason=f"Account '{target_account}' not allowed for trust tier '{tier}'",
            cited_rule=cited,
        )


def build_rollback_plan(
    agent: AgentInfo,
    action: str,
    target_harness: str | None,
    target_account: str | None,
) -> dict[str, Any]:
    """Build a rollback plan for a mutating action."""
    return {
        "reverse_action": action,
        "original_harness": agent.current_harness,
        "original_account": agent.current_account,
        "target_harness": target_harness,
        "target_account": target_account,
        "agent_name": agent.name,
    }


def decide(
    fleet_state: FleetState,
    agent: AgentInfo,
    trigger: Trigger,
    config: RotationConfig,
) -> Decision:
    """Return a Decision for the given context, or raise NoRuleMatched.

    Pure function: no I/O, no side effects, deterministic.
    """
    tier = resolve_trust_tier(agent.name, config.role_trust_map)

    for idx, rule in enumerate(config.decisions):
        if not _match_rule(rule, trigger, agent, tier):
            continue

        action = rule.get("action", "pause_not_respawn")
        target_harness: str | None = None
        target_account: str | None = None

        if action == "flip_cross_harness":
            target_harness = _pick_target_harness(rule, fleet_state, tier, config)
            if target_harness is None and rule.get("target_harness") == "from_cli_arg":
                # Pull from trigger metadata
                target_harness = trigger.metadata.get("target_harness")

            if target_harness is None:
                action = rule.get("fallback", "pause_not_respawn")
            else:
                target_account = _pick_target_account(target_harness, fleet_state, tier, config)
                if target_account is None:
                    action = rule.get("fallback", "pause_not_respawn")
                else:
                    # Hard gate: trust-tier enforcement
                    enforce_trust_tier(tier, target_account, config)

        # respawn_preserve_identity: only valid if current account is healthy
        if action == "respawn_preserve_identity":
            current_healthy = [
                a for a in fleet_state.accounts
                if a.label == agent.current_account and a.current_state == "active"
            ]
            if not current_healthy:
                action = rule.get("fallback", "pause_not_respawn")

        # Non-flip actions don't need target resolution
        cited_rule = f"rule-{idx}-{trigger.type}-{tier}"
        rollback = build_rollback_plan(agent, action, target_harness, target_account)

        return Decision(
            action=action,
            cited_rule=cited_rule,
            target_harness=target_harness if action == "flip_cross_harness" else None,
            target_account=target_account if action == "flip_cross_harness" else None,
            rollback_plan=rollback,
        )

    raise NoRuleMatched(trigger, agent)


# ── Config loader ───────────────────────────────────────────────────


def load_config(path: Path | None = None) -> RotationConfig:
    """Load rotation config from YAML. Requires PyYAML or uses minimal parser."""
    if path is None:
        path = Path(__file__).with_name("config.yaml")

    try:
        import yaml
        data = yaml.safe_load(path.read_text())
        return RotationConfig.from_dict(data)
    except ImportError:
        # Minimal fallback — enough for the decision engine tests
        return _parse_minimal_yaml(path)


def _parse_minimal_yaml(path: Path) -> RotationConfig:
    """Minimal YAML parser sufficient for config.yaml structure."""
    text = path.read_text()
    data: dict[str, Any] = {
        "schema_version": 1,
        "harnesses": {},
        "providers": {},
        "accounts": [],
        "trust_tiers": {},
        "role_trust_map": [],
        "triggers": {},
        "decisions": [],
    }

    section = None
    current_account: dict[str, str] = {}
    current_tier: dict[str, Any] = {}
    current_harness: dict[str, Any] = {}
    in_accounts = False
    in_tiers = False
    in_harnesses = False
    in_role_map = False
    in_triggers = False
    in_decisions = False
    current_decision: dict[str, Any] = {}

    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        # Top-level section detection
        if stripped == "accounts:":
            in_accounts = True
            in_tiers = in_harnesses = in_role_map = in_triggers = in_decisions = False
            continue
        if stripped == "trust_tiers:":
            in_tiers = True
            in_accounts = in_harnesses = in_role_map = in_triggers = in_decisions = False
            continue
        if stripped == "harnesses:":
            in_harnesses = True
            in_accounts = in_tiers = in_role_map = in_triggers = in_decisions = False
            continue
        if stripped == "role_trust_map:":
            in_role_map = True
            in_accounts = in_tiers = in_harnesses = in_triggers = in_decisions = False
            continue
        if stripped == "triggers:":
            in_triggers = True
            in_accounts = in_tiers = in_harnesses = in_role_map = in_decisions = False
            continue
        if stripped == "decisions:":
            in_decisions = True
            in_accounts = in_tiers = in_harnesses = in_role_map = in_triggers = False
            continue

        # Harnesses
        if in_harnesses and not stripped.startswith("-"):
            if re.match(r"^\w+:", stripped) and not any(
                stripped.startswith(k) for k in ("command", "config_dir", "quota", "mcp", "parent")
            ):
                if current_harness:
                    data["harnesses"][current_harness["_name"]] = {
                        k: v for k, v in current_harness.items() if not k.startswith("_")
                    }
                current_harness = {"_name": stripped.rstrip(":")}
            else:
                m = re.match(r"(\w+):\s*(.+)", stripped)
                if m and current_harness:
                    current_harness[m.group(1)] = m.group(2).strip()

        # Accounts
        if in_accounts:
            if stripped.startswith("-"):
                if current_account:
                    data["accounts"].append(dict(current_account))
                current_account = {}
                m = re.match(r"-\s+(\w+):\s*(.+)", stripped)
                if m:
                    current_account[m.group(1)] = m.group(2).strip()
            else:
                m = re.match(r"(\w+):\s*(.+)", stripped)
                if m:
                    current_account[m.group(1)] = m.group(2).strip()

        # Trust tiers
        if in_tiers and not in_role_map and not in_triggers and not in_decisions:
            if re.match(r"^\w+:$", stripped) and stripped != "trust_tiers:":
                if current_tier:
                    data["trust_tiers"][current_tier["_name"]] = {
                        k: v for k, v in current_tier.items() if not k.startswith("_")
                    }
                current_tier = {"_name": stripped.rstrip(":")}
            elif current_tier:
                m = re.match(r"(\w+):\s*(.+)", stripped)
                if m:
                    k, v = m.group(1), m.group(2).strip()
                    if k == "allowed_accounts":
                        current_tier[k] = [
                            x.strip().strip('"').strip("'")
                            for x in v.strip("[]").split(",")
                        ]
                    else:
                        current_tier[k] = v

        # Role trust map
        if in_role_map:
            m = re.match(r"-\s+pattern:\s*(.+)", stripped)
            if m:
                current_entry = {"pattern": m.group(1).strip().strip('"').strip("'")}
            else:
                m = re.match(r"tier:\s*(.+)", stripped)
                if m and "current_entry" in dir():
                    current_entry["tier"] = m.group(1).strip()
                    data["role_trust_map"].append(current_entry)

        # Triggers
        if in_triggers:
            m = re.match(r"^(\w+):$", stripped)
            if m:
                current_trigger = {"_name": m.group(1)}
            elif "current_trigger" in dir():
                m = re.match(r"(\w+):\s*(.+)", stripped)
                if m:
                    current_trigger[m.group(1)] = m.group(2).strip()
                    data["triggers"][current_trigger["_name"]] = {
                        k: v for k, v in current_trigger.items() if not k.startswith("_")
                    }

        # Decisions
        if in_decisions:
            if stripped.startswith("-"):
                if current_decision:
                    data["decisions"].append(dict(current_decision))
                current_decision = {}
            else:
                m = re.match(r"(\w+):\s*(.+)", stripped)
                if m:
                    k, v = m.group(1), m.group(2).strip()
                    if k == "target_harness_priority":
                        current_decision[k] = [
                            x.strip().strip('"').strip("'")
                            for x in v.strip("[]").split(",")
                        ]
                    else:
                        current_decision[k] = v

    # Flush pending
    if current_harness:
        data["harnesses"][current_harness["_name"]] = {
            k: v for k, v in current_harness.items() if not k.startswith("_")
        }
    if current_account:
        data["accounts"].append(dict(current_account))
    if current_tier:
        data["trust_tiers"][current_tier["_name"]] = {
            k: v for k, v in current_tier.items() if not k.startswith("_")
        }
    if current_decision:
        data["decisions"].append(dict(current_decision))

    return RotationConfig.from_dict(data)


# ── CLI ─────────────────────────────────────────────────────────────


def main() -> int:
    import argparse
    import json

    parser = argparse.ArgumentParser(description="hats rotation decision engine")
    parser.add_argument("--config", type=Path, default=None)
    parser.add_argument("--agent-name", required=True)
    parser.add_argument("--agent-role", default="project-engineer")
    parser.add_argument("--current-harness", required=True)
    parser.add_argument("--current-account", required=True)
    parser.add_argument("--trigger", required=True)
    parser.add_argument("--target-harness", default=None)
    parser.add_argument("--fleet-state", type=str, default="[]",
                        help='JSON array of {"label":"x","harness":"y","current_state":"z"}')
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    config = load_config(args.config)

    fleet_accounts = tuple(
        AccountState(label=a["label"], harness=a["harness"], current_state=a["current_state"])
        for a in json.loads(args.fleet_state)
    )
    fleet_state = FleetState(accounts=fleet_accounts)

    agent = AgentInfo(
        name=args.agent_name,
        role=args.agent_role,
        current_harness=args.current_harness,
        current_account=args.current_account,
    )

    trigger = Trigger(
        type=args.trigger,
        metadata={"target_harness": args.target_harness} if args.target_harness else {},
    )

    try:
        decision = decide(fleet_state, agent, trigger, config)
    except RefusedTransition as e:
        result = {"refused": True, "reason": e.reason, "cited_rule": e.cited_rule}
        print(json.dumps(result) if args.json else f"REFUSED: {e.reason} ({e.cited_rule})")
        return 1
    except NoRuleMatched as e:
        result = {"error": "no_rule_matched", "trigger": e.trigger.type, "agent": e.agent.name}
        print(json.dumps(result) if args.json else f"ERROR: No rule matched for {e.agent.name} + {e.trigger.type}")
        return 2

    result = {
        "action": decision.action,
        "cited_rule": decision.cited_rule,
        "target_harness": decision.target_harness,
        "target_account": decision.target_account,
        "rollback_plan": decision.rollback_plan,
    }
    print(json.dumps(result, indent=2) if args.json else f"ACTION: {decision.action}  rule={decision.cited_rule}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
