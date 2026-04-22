#!/usr/bin/env python3
"""
hats rotation pool status — credential pool health monitor.

Reads rotation/config.yaml and queries live account states via the hats CLI,
producing a formatted health report with quota readiness and rotation
recommendations.
"""

import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


CONFIG_PATH = Path(__file__).with_name("config.yaml")
HATS_SCRIPT = Path(__file__).parent.parent / "hats"


@dataclass
class Account:
    label: str
    harness: str
    provider: str
    trust_tier: str
    quota_model: str
    current_state: str = "unknown"
    auth_status: str = "unknown"
    expires: Optional[str] = None
    default: bool = False
    issues: list = field(default_factory=list)


@dataclass
class PoolReport:
    accounts: list[Account]
    healthy_count: int = 0
    warn_count: int = 0
    crit_count: int = 0


def _run_hats(*args: str) -> tuple[int, str]:
    """Run the hats CLI and return (rc, stdout)."""
    cmd = [str(HATS_SCRIPT), *args]
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=30, check=False
        )
        return result.returncode, result.stdout + result.stderr
    except subprocess.TimeoutExpired:
        return 124, "(timeout)"
    except FileNotFoundError:
        return 127, f"(hats not found at {HATS_SCRIPT})"


_ACCOUNT_KEYS = {"label", "harness", "provider", "trust_tier", "quota_model", "current_state"}


def _parse_yaml_accounts(path: Path) -> list[Account]:
    """Minimal YAML parser for the account catalog section."""
    if not path.exists():
        print(f"Error: config not found: {path}", file=sys.stderr)
        sys.exit(1)

    text = path.read_text()
    accounts: list[Account] = []
    in_accounts = False
    current: dict[str, str] = {}

    for line in text.splitlines():
        stripped = line.strip()

        if stripped == "accounts:":
            in_accounts = True
            continue

        # Exit accounts section on next top-level key
        if in_accounts and stripped and not stripped.startswith("#"):
            if not line.startswith(" ") and not line.startswith("-"):
                if stripped.endswith(":"):
                    in_accounts = False
                    continue

        if not in_accounts:
            continue

        if stripped.startswith("-"):
            # Flush previous account
            if current and "label" in current:
                accounts.append(
                    Account(
                        label=current.get("label", "?"),
                        harness=current.get("harness", "?"),
                        provider=current.get("provider", "?"),
                        trust_tier=current.get("trust_tier", "?"),
                        quota_model=current.get("quota_model", "?"),
                        current_state=current.get("current_state", "unknown"),
                    )
                )
            current = {}
            # Parse "- label: foo" inline
            match = re.match(r"-\s+(\w+):\s*(.+)", stripped)
            if match and match.group(1) in _ACCOUNT_KEYS:
                current[match.group(1)] = match.group(2).strip()
            continue

        if stripped and not stripped.startswith("#"):
            match = re.match(r"(\w+):\s*(.+)", stripped)
            if match and match.group(1) in _ACCOUNT_KEYS:
                current[match.group(1)] = match.group(2).strip()

    if current and "label" in current:
        accounts.append(
            Account(
                label=current.get("label", "?"),
                harness=current.get("harness", "?"),
                provider=current.get("provider", "?"),
                trust_tier=current.get("trust_tier", "?"),
                quota_model=current.get("quota_model", "?"),
                current_state=current.get("current_state", "unknown"),
            )
        )

    return accounts


def _query_claude_accounts() -> dict[str, dict]:
    """Query claude account states via 'hats list'."""
    rc, out = _run_hats("list")
    if rc != 0:
        return {}

    accounts: dict[str, dict] = {}
    # Parse lines like:
    #   debussy      ok (expires 2026-04-23) [rc]
    # * shannon      ok (access expired, will auto-refresh) [rc]
    #   kimi         NO CREDENTIALS
    for line in out.splitlines():
        match = re.match(
            r"^(\s*)(\*|\s)\s+(\S+)\s+(.+)$",
            line,
        )
        if not match:
            continue
        default_mark = match.group(2).strip()
        name = match.group(3).strip()
        status = match.group(4).strip()

        auth_status = "unknown"
        expires = None
        issues: list[str] = []

        if "NO CREDENTIALS" in status:
            auth_status = "no_credentials"
            issues.append("No credentials configured")
        elif status.startswith("ok"):
            auth_status = "ok"
            # Extract expiry info from parentheses
            expiry_match = re.search(r"\(([^)]+)\)", status)
            if expiry_match:
                expires = expiry_match.group(1)
                if "expired" in expires.lower():
                    issues.append(f"Token expired: {expires}")
        else:
            auth_status = status

        accounts[name] = {
            "auth_status": auth_status,
            "expires": expires,
            "default": default_mark == "*",
            "issues": issues,
        }

    return accounts


def _query_codex_accounts() -> dict[str, dict]:
    """Query codex account states via 'hats codex list'."""
    rc, out = _run_hats("codex", "list")
    if rc != 0:
        return {}

    accounts: dict[str, dict] = {}
    for line in out.splitlines():
        match = re.match(r"^(\s*)(\*|\s)\s+(\S+)\s+(.+)$", line)
        if not match:
            continue
        default_mark = match.group(2).strip()
        name = match.group(3).strip()
        status = match.group(4).strip()

        auth_status = "unknown"
        expires = None
        issues: list[str] = []

        if status.startswith("ok"):
            auth_status = "ok"
            expiry_match = re.search(r"\(([^)]+)\)", status)
            if expiry_match:
                expires = expiry_match.group(1)
                if "expired" in expires.lower():
                    issues.append(f"Token expired: {expires}")
        else:
            auth_status = status

        accounts[name] = {
            "auth_status": auth_status,
            "expires": expires,
            "default": default_mark == "*",
            "issues": issues,
        }

    return accounts


def _query_kimi_account() -> dict[str, dict]:
    """Query kimi-specific health via 'hats kimi doctor'."""
    rc, out = _run_hats("kimi", "doctor")
    issues: list[str] = []
    auth_status = "unknown"

    if rc != 0:
        auth_status = "doctor_failed"
        issues.append(f"hats kimi doctor failed (rc={rc})")
    else:
        # Count OK vs FAIL vs WARN
        ok_count = out.count("  OK ")
        fail_count = out.count("  FAIL ")
        warn_count = out.count("  WARN ")

        if fail_count > 0:
            auth_status = "degraded"
            issues.append(f"{fail_count} doctor failure(s)")
        elif warn_count > 0:
            auth_status = "ok_with_warn"
            issues.append(f"{warn_count} doctor warning(s)")
        else:
            auth_status = "ok"

        # Parse "Done. N issue(s)" line
        issue_match = re.search(r"Done\.\s+(\d+)\s+issue\(s\)", out)
        if issue_match:
            issue_count = int(issue_match.group(1))
            if issue_count > 0 and not issues:
                issues.append(f"{issue_count} issue(s) detected")

    return {
        "kimi": {
            "auth_status": auth_status,
            "expires": None,
            "default": False,
            "issues": issues,
        }
    }


def build_report() -> PoolReport:
    """Query live state and build a pool health report."""
    accounts = _parse_yaml_accounts(CONFIG_PATH)
    claude_live = _query_claude_accounts()
    codex_live = _query_codex_accounts()
    kimi_live = _query_kimi_account()

    healthy = 0
    warn = 0
    crit = 0

    for acct in accounts:
        live: dict = {}
        if acct.harness in ("claude-code", "claude-via-kimi-anthropic"):
            if acct.label == "kimi":
                live = kimi_live.get("kimi", {})
            else:
                live = claude_live.get(acct.label, {})
        elif acct.harness == "codex":
            live = codex_live.get(acct.label, {})

        acct.auth_status = live.get("auth_status", "unknown")
        acct.expires = live.get("expires")
        acct.default = live.get("default", False)
        acct.issues = live.get("issues", [])

        # Categorize health
        if acct.auth_status == "ok" and not acct.issues:
            healthy += 1
        elif acct.auth_status in ("ok", "ok_with_warn") or (
            acct.auth_status == "ok" and acct.issues
        ):
            # Expired-but-refreshable is warn, not crit
            warn += 1
        elif acct.auth_status == "no_credentials":
            crit += 1
        elif acct.auth_status in ("doctor_failed", "degraded"):
            crit += 1
        else:
            warn += 1

    return PoolReport(
        accounts=accounts,
        healthy_count=healthy,
        warn_count=warn,
        crit_count=crit,
    )


def _format_report(report: PoolReport, output_format: str = "human") -> str:
    """Format the report for display."""
    if output_format == "json":
        return json.dumps(
            {
                "schema_version": 1,
                "healthy": report.healthy_count,
                "warn": report.warn_count,
                "crit": report.crit_count,
                "accounts": [
                    {
                        "label": a.label,
                        "harness": a.harness,
                        "provider": a.provider,
                        "trust_tier": a.trust_tier,
                        "auth_status": a.auth_status,
                        "expires": a.expires,
                        "default": a.default,
                        "issues": a.issues,
                    }
                    for a in report.accounts
                ],
            },
            indent=2,
        )

    lines: list[str] = []
    lines.append(f"hats rotation pool status")
    lines.append(f"")
    lines.append(
        f"  Healthy: {report.healthy_count}  Warn: {report.warn_count}  "
        f"Critical: {report.crit_count}"
    )
    lines.append(f"")

    # Group by harness
    by_harness: dict[str, list[Account]] = {}
    for a in report.accounts:
        by_harness.setdefault(a.harness, []).append(a)

    for harness, accts in by_harness.items():
        lines.append(f"  {harness}")
        lines.append(f"  {'─' * 50}")
        for a in accts:
            default_mark = "*" if a.default else " "
            status_icon = "✓" if a.auth_status == "ok" and not a.issues else "!"
            if a.auth_status in ("no_credentials", "doctor_failed", "degraded"):
                status_icon = "✗"

            tier_tag = f"[{a.trust_tier}]"
            lines.append(
                f"  {default_mark} {status_icon} {a.label:<12} {a.auth_status:<15} {tier_tag}"
            )
            if a.expires:
                lines.append(f"      expires: {a.expires}")
            for issue in a.issues:
                lines.append(f"      ! {issue}")
        lines.append(f"")

    # Rotation readiness summary
    lines.append("  Rotation Readiness")
    lines.append(f"  {'─' * 50}")

    ops_ready = [
        a.label
        for a in report.accounts
        if a.trust_tier == "ops" and a.auth_status not in ("no_credentials", "doctor_failed", "degraded")
    ]
    content_ready = [
        a.label
        for a in report.accounts
        if a.auth_status not in ("no_credentials", "doctor_failed", "degraded")
    ]

    lines.append(f"    ops-eligible:     {', '.join(ops_ready) or '(none)'}")
    lines.append(f"    content-eligible: {', '.join(content_ready) or '(none)'}")

    if report.crit_count > 0:
        lines.append(f"")
        lines.append(f"  ⚠ {report.crit_count} account(s) need attention")

    return "\n".join(lines)


def main() -> int:
    output_format = "human"
    args = sys.argv[1:]

    if "--json" in args:
        output_format = "json"

    report = build_report()
    print(_format_report(report, output_format))
    return 0 if report.crit_count == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
