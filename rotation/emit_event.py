#!/usr/bin/env python3
"""Emit queued rotation events for mesh consumption.

Reads event JSON files from ~/.hats/rotation/events/, validates each
against events.schema.json, and emits them as JSON lines to stdout.
A mesh agent (or wrapper) reads stdout and forwards via send_message.

Usage:
    python3 emit_event.py              # emit all queued events
    python3 emit_event.py --dry-run    # validate only, do not move files
    python3 emit_event.py --json       # machine-readable output
    python3 emit_event.py --latest     # emit only the most recent event

Exit codes:
    0  all events emitted/validated successfully
    1  one or more events failed validation
    2  schema or directory missing
"""

import json
import os
import sys
from pathlib import Path


def find_rotation_dir():
    """Locate the rotation directory (script dir first, then HATS_DIR)."""
    script_dir = Path(__file__).resolve().parent
    if script_dir.exists() and (script_dir / "events.schema.json").exists():
        return script_dir
    hats_dir = os.environ.get("HATS_DIR", os.path.expanduser("~/.hats"))
    return Path(hats_dir) / "rotation"


def load_schema(rotation_dir: Path):
    schema_path = rotation_dir / "events.schema.json"
    if not schema_path.exists():
        print(f"Error: schema not found: {schema_path}", file=sys.stderr)
        sys.exit(2)
    with open(schema_path) as f:
        return json.load(f)


def validate_event(event: dict, schema: dict) -> list:
    """Basic validation against schema. Returns list of error strings."""
    errors = []
    required = schema.get("required", [])
    for key in required:
        if key not in event:
            errors.append(f"missing required field: {key}")

    props = schema.get("properties", {})
    for key, value in event.items():
        if key not in props:
            errors.append(f"unknown field: {key}")
            continue
        prop = props[key]
        types = prop.get("type", [])
        if not isinstance(types, list):
            types = [types]

        # null check
        if value is None and "null" in types:
            continue

        # type check
        type_ok = False
        for t in types:
            if t == "string" and isinstance(value, str):
                type_ok = True
                break
            if t == "integer" and isinstance(value, int):
                type_ok = True
                break
            if t == "boolean" and isinstance(value, bool):
                type_ok = True
                break
        if not type_ok:
            errors.append(f"field {key}: expected {types}, got {type(value).__name__}")

        # enum check
        enum = prop.get("enum", [])
        if enum and value is not None and value not in enum:
            errors.append(f"field {key}: value {value!r} not in enum {enum}")

        # pattern check (simplified — just event_id)
        pattern = prop.get("pattern", "")
        if pattern and isinstance(value, str):
            import re
            if not re.match(pattern, value):
                errors.append(f"field {key}: value {value!r} does not match pattern {pattern}")

    return errors


def emit_events(dry_run: bool, latest_only: bool) -> int:
    rotation_dir = find_rotation_dir()
    schema = load_schema(rotation_dir)

    # Events always live under HATS_DIR (not the script dir)
    hats_dir = os.environ.get("HATS_DIR", os.path.expanduser("~/.hats"))
    events_dir = Path(hats_dir) / "rotation" / "events"
    sent_dir = Path(hats_dir) / "rotation" / "events_sent"

    if not events_dir.exists():
        print(f"Error: events directory not found: {events_dir}", file=sys.stderr)
        return 2

    event_files = sorted(
        [f for f in events_dir.iterdir() if f.suffix == ".json"],
        key=lambda f: f.stat().st_mtime,
    )

    if latest_only and event_files:
        event_files = event_files[-1:]

    if not event_files:
        return 0

    all_ok = True
    for event_file in event_files:
        try:
            with open(event_file) as f:
                event = json.load(f)
        except json.JSONDecodeError as e:
            print(f"Error: invalid JSON in {event_file.name}: {e}", file=sys.stderr)
            all_ok = False
            continue
        except Exception as e:
            print(f"Error: reading {event_file.name}: {e}", file=sys.stderr)
            all_ok = False
            continue

        errors = validate_event(event, schema)
        if errors:
            print(f"Error: validation failed for {event_file.name}:", file=sys.stderr)
            for err in errors:
                print(f"  - {err}", file=sys.stderr)
            all_ok = False
            continue

        # Emit: print as JSON line to stdout
        print(json.dumps(event, separators=(",", ":")))

        if not dry_run:
            sent_dir.mkdir(parents=True, exist_ok=True)
            target = sent_dir / event_file.name
            try:
                event_file.rename(target)
            except Exception as e:
                print(f"Error: could not move {event_file.name} to sent: {e}", file=sys.stderr)
                all_ok = False

    return 0 if all_ok else 1


def main():
    dry_run = "--dry-run" in sys.argv
    latest_only = "--latest" in sys.argv
    rc = emit_events(dry_run=dry_run, latest_only=latest_only)
    sys.exit(rc)


if __name__ == "__main__":
    main()
