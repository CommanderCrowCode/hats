# `hats doctor` — check catalog

Reference for every check `hats doctor` runs, what it means, and how to
remediate. Ordered by section number as emitted by the command.

Doctor is **read-only**. It never mutates state. Section 1 runs once; sections
2* run against `base/`; section 3 checks the runtime symlink; section 4*
loops per account.

---

## 1. Tooling

### `OK/FAIL python3 found`

- **What.** Verifies `python3` is on `$PATH`.
- **Why.** Used by `hats list` (token inspection) and several doctor checks
  (JSON validity, hook-path extraction, duplicate-hook fingerprinting).
- **Remediate FAIL.** Install Python 3 via your OS package manager. No version
  constraints — 3.8+ is safe.

### `OK/FAIL <provider> found`

- **What.** Verifies the provider CLI (`claude` or `codex`) is on `$PATH`.
- **Why.** `hats swap` and the shell-generated account functions invoke this
  binary directly.
- **Remediate FAIL.** Install the provider per its upstream instructions and
  ensure the binary is on `$PATH`.

---

## 2. Layout

### `OK/FAIL provider dir <path>`

- **What.** Verifies `~/.hats/<provider>/` exists as a directory.
- **Remediate FAIL.** Run `hats init` (or `hats codex init`).

### `OK/FAIL base dir <path>`

- **What.** Verifies `~/.hats/<provider>/base/` exists as a directory.
- **Why.** All shared-resource symlinks resolve here.
- **Remediate FAIL.** Re-run `hats init` — it creates `base/` on first use.

---

## 2b. Base config JSON validity (claude only)

### `OK/FAIL base/<file> parses as JSON`

- **What.** Python-parses `base/settings.json`, `base/hooks.json`, and
  `base/.mcp.json` if present.
- **Why.** Claude-code silently rejects invalid JSON config and falls back to
  defaults. The failure mode is "my session doesn't seem to load settings"
  without a clear error — this check makes it loud.
- **Remediate FAIL.** Open the named file, find the syntax error (the parser
  will give you line + column in its normal error output if you re-run
  `python3 -m json.tool < file`), and fix it. Common causes: trailing
  comma, un-escaped string.

---

## 2d. Hook command paths (claude only)

### `OK/FAIL hook command missing: <path>`

- **What.** Walks `base/settings.json`'s `hooks.<event>[].hooks[].command`
  tree and checks each unique command path for existence.
- **Why.** Claude-code skips hooks whose command paths don't resolve, which
  is especially painful for mesh-registration and security hooks that need
  to fire on every tool call.
- **Remediate FAIL.** Either correct the path in `base/settings.json` or
  create the missing script. Tilde is expanded to `$HOME` before stat'ing;
  other shell expansions are left to claude-code runtime.

### `OK/FAIL hook command not executable: <path>`

- **What.** Command path exists but lacks the execute bit.
- **Remediate FAIL.** `chmod +x <path>`.

---

## 2e. Duplicate hook registrations (claude only)

### `OK/WARN duplicate hook registration: event=X matcher=Y count=N (run 'hats fix' to dedupe)`

- **What.** Fingerprints every entry under `hooks.<event>` as
  `(matcher, sorted-command-paths)` and flags fingerprints that appear
  more than once within the same event.
- **Why.** Duplicated entries cause claude-code to run the hook N times per
  matching tool call — usually benign but wasteful, and non-idempotent hook
  scripts can produce surprising side effects.
- **Remediate WARN.** Run `hats fix`. It rewrites `base/settings.json`
  atomically, collapsing each event's hook list to one entry per
  `(matcher, command-set)` fingerprint. First occurrence wins; remaining
  ordering is preserved; unique entries are left verbatim. Fix emits one
  line per event+matcher that had removals:
  `deduped base/settings.json hooks: event=<E> matcher=<M> removed=<N>`.

---

## 2f. Symlink-target validation

### `OK/WARN base/<name> symlink resolves outside $HOME: <target>`

- **What.** Resolves every symlink under `base/` via `_realpath` and
  flags targets that fall outside `$HOME`.
- **Why.** A mistaken or malicious symlink at, e.g., `base/settings.json
  -> /etc/shadow` would be propagated into every account via `hats fix`
  and read by claude-code. Targets inside `$HOME` are assumed user-owned
  and pass silently.
- **Remediate WARN.** Inspect the symlink. If the target is legitimate
  (e.g. a shared scripts dir you maintain in `/opt`), ignore — or move
  the target under `$HOME` to suppress the warning. If the target is
  unexpected, remove the symlink (`rm base/<name>`) and restore it from
  a known-good source.

---

## 2c. Orphan isolated resources in base

### `OK/WARN orphan isolated resource in base: <name>`

- **What.** Iterates `base/` and flags any file whose basename matches the
  provider's `ISOLATED_PATTERNS` (e.g. `.credentials.json`, `auth.json`,
  `history.jsonl`, `sessions`).
- **Why.** Isolated resources belong per-account only. A stray copy in
  `base/` is a migration artifact and a credential-leak vector: on
  `hats fix` or new-account creation, `base/<orphan>` would be symlinked
  into every new account, silently propagating leaked tokens.
- **Remediate WARN.** Inspect the file. If it contains credentials, rotate
  them first, then delete the orphan. If it's an empty stub or a legacy
  artifact, just delete it.

---

## 3. Default-account runtime symlink

### `OK/FAIL ~/.<provider> -> default account 'X'`

- **What.** Verifies `~/.claude` (or `~/.codex`) resolves to the account
  named in config as the default.
- **Why.** Bare `claude` / `codex` invocations follow this symlink; drift
  here means "running bare `claude` uses a different account than
  `hats default` reports".
- **Remediate FAIL.** Typically `hats fix`. **Exception:** if your
  `~/.hats/config.toml` has a legacy `default = "..."` key (v0.x format),
  upgrade to v1.1+ first — `hats` auto-migrates on the next invocation.
  Running `hats fix` *before* the migration can point the symlink at the
  wrong account. See issue #2.

### `WARN ~/.<provider> missing`

- **What.** No runtime symlink present.
- **Remediate WARN.** Run `hats default <name>` to set a default account —
  this creates the symlink as a side effect.

---

## 4a. Primary auth file (per account)

### `OK/FAIL <authfile> missing`

- **What.** Each account must have its primary auth file
  (`.credentials.json` for claude, `auth.json` for codex).
- **Kimi exception.** The Claude-side `kimi` slot is API-key-backed and
  intentionally has no `.credentials.json`; doctor reports this as
  `OK   Kimi API-key account — no .credentials.json expected`.
- **Remediate FAIL.** Re-authenticate the account. For claude:
  `hats swap <name>` then `/login`; exit. For codex: `hats codex add <name>
  --chatgpt|--api-key|--device-auth`.

### `OK/WARN <authfile> mode=NNN`

- **What.** Verifies the auth file has mode 600 or 400 (owner-only).
- **Why.** Credentials must not be group/other readable — this is a
  baseline file-permission hygiene check.
- **Remediate WARN.** `chmod 600 <authfile>`.

---

## 4b. Broken symlinks (per account)

### `OK/FAIL broken symlink: <name>`

- **What.** A symlink exists in the account dir but its target doesn't.
- **Why.** Usually indicates `base/<name>` was deleted after the symlink
  was created.
- **Remediate FAIL.** Run `hats fix` — it removes broken symlinks and
  repairs any that still have a valid target in `base/`.

---

## 4c. Missing shared resources (per account)

### `OK/WARN missing shared resource: <name>`

- **What.** A file exists in `base/` (not in `ISOLATED_PATTERNS`, meant to
  be shared) but the account dir has neither file nor symlink for it.
- **Why.** New shared resources added to `base/` don't auto-propagate; older
  accounts will miss them until their symlinks are refreshed.
- **Remediate WARN.** Run `hats fix` — it adds missing symlinks.

---

## 4d. Locally-overridden shared resources (per account)

### `OK/WARN locally-overridden shared resource: <name>`

- **What.** The account has a regular file (not a symlink) with the same
  name as a shared resource in `base/`.
- **Why.** Usually intentional — someone ran `hats unlink <account>
  <resource>` to maintain a per-account copy. But it's also how drift
  sneaks in unnoticed (e.g. an older settings.json that never got
  re-linked).
- **Remediate WARN.** If the divergence is intentional, leave it. If not,
  run `hats link <account> <resource>` to restore the symlink to `base/`.
  The local copy is replaced.

---

## Memory probe (per account)

### `OK/FAIL memory praetor MEMORY.md (shared + identical)`

- **What.** If `base/projects/-home-tanwa-praetor/memory/MEMORY.md` exists,
  verify the account resolves the same path to a byte-identical file.
- **Why.** Quick sanity check that the `projects/` symlink is wired
  correctly across all accounts. A mismatch means cross-credential memory
  drift — exactly the class of bug the cross-credential-consistency audit
  (see `cross-credential-consistency-2026-04-17.md`) was commissioned to
  find.
- **Remediate FAIL.** Re-run `hats fix` on the offending account; if that
  doesn't help, inspect `readlink -f <account>/projects` and compare
  against `readlink -f base/projects`.

---

## Exit codes

| Code | Meaning |
|------|---------|
| 0    | All checks pass (WARN allowed) |
| 1    | At least one hard issue (FAIL) |
| 2    | Invalid invocation / layout missing |

`hats doctor` is idempotent, read-only, cron-friendly. Pipe through `grep
FAIL` for machine-readable issue extraction.

## Related

- `tests/smoke.sh` — regression harness exercising every check on a sandbox
- `hats fix` — the write counterpart that auto-repairs what doctor surfaces
- `docs/cross-credential-consistency-2026-04-17.md` — research doc that
  motivated several of these checks
