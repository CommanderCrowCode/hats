# Security

## Threat Model

hats manages local Claude Code and Codex authentication state on a machine. The primary security concerns are:

1. **Credential confidentiality** — preventing unauthorized access to tokens
2. **Credential integrity** — preventing corruption or cross-contamination
3. **Session isolation** — ensuring the right credentials reach the right session

## Current Security (v1.1)

### What's Protected

**Session isolation:** Each account has its own provider-scoped directory. Claude uses isolated `CLAUDE_CONFIG_DIR` directories and Codex uses isolated `CODEX_HOME` directories. Concurrent sessions never touch each other's auth or runtime state.

**File permissions:** Account credential files are created with `chmod 600` (owner read/write only). No group or world access.

**No credential swapping:** Unlike v0.2.x, credentials are never copied between files. Each account's auth file is written to directly by the provider CLI (`.credentials.json` for Claude, file-backed Codex credentials under `CODEX_HOME`). This eliminates the entire class of save-back corruption bugs.

**No shared mutable state:** Runtime state is isolated per account. For Claude that includes `.claude.json`; for Codex it includes auth, history, sessions, caches, and sqlite state files.

**Environment cleanup:** `CLAUDE_CODE_OAUTH_TOKEN` is not used. Sessions are scoped by `CLAUDE_CONFIG_DIR` or `CODEX_HOME`, depending on provider.

**No network exposure:** hats never transmits credentials. All operations are local file and symlink management.

### What's NOT Protected

**Plaintext on disk:** Credential files (access tokens + refresh tokens) are stored as plaintext JSON. Any process running as your user can read them. This is the same security model as Claude Code itself — hats doesn't make it worse, but doesn't improve it either.

**Symlinked shared resources:** Some resources are shared across accounts via symlinks by default. A compromised account's session could modify shared settings or config. Use `hats unlink` to isolate sensitive config per account.

**Codex keyring mode:** Codex support assumes `cli_auth_credentials_store = "file"`. This remains true whether the account authenticates via ChatGPT login, API key login, or device auth. If a user changes Codex to use OS keyring storage, hats can no longer guarantee that each account's credentials live entirely inside its account directory.

**No audit logging:** hats doesn't log which account was used when. This is a feature gap for shared machines.

## Recommendations

### For Personal Machines (Most Users)

The current security model is adequate:
- Your user account is the trust boundary
- File permissions prevent other users from reading credentials
- Full-disk encryption (LUKS, FileVault) protects against physical access
- Claude Code itself uses the same plaintext storage

### For Shared Machines

Additional precautions:
- Ensure `~/.hats/` is not world-readable
- Use full-disk encryption
- Consider `hats unlink` for sensitive config files per account
- Monitor credential files for unexpected access (inotifywait, auditd)

### General

- Never commit credential files to git
- If you suspect a token is compromised, revoke it at [console.anthropic.com](https://console.anthropic.com) and re-run `/login`
- Back up account directories periodically (`cp -a ~/.hats/claude/<name> /backup/`)

## Audit History

### 2026-04-17 — full-script audit

An automated code-reviewer agent audited the entire `hats` script + companion
`install.sh` / `tests/smoke.sh` for shell injection, path traversal, command
injection, credential leakage, permission handling, race conditions, and
symlink-target validation.

**Findings + resolutions:**

| # | Severity | Finding | Resolution | Commit |
|---|----------|---------|------------|--------|
| 1 | Critical | `_token_info_claude` / `_token_info_codex` interpolated `$file` into a python heredoc (`python3 -c "…open('$file')…"`), so a `HATS_DIR` containing a single quote could break out into Python code execution | Switched to argv-based invocation: `python3 - "$file" <<'PYEOF' … sys.argv[1]`; the heredoc is single-quoted so no shell substitution inside | a89d741 |
| 2 | High | `_config_set` interpolated `$value` into `sed` replacement + `awk -v val=$value`. `#`, `&`, `\`, `\n` could corrupt config or affect expression parsing | Rewrote `_config_set` as a python3 read/modify/write using `json.dumps()` for TOML-safe escaping + atomic `os.replace` | 0f73b1d |
| 3 | High | `install.sh` interpolated `$COMMIT` (from `git rev-parse`) into a `sed` replacement. Under a tampered `.git`, a ref containing `/`, `&`, or `\n` could corrupt the stamping expression | Constrained `$COMMIT` to `^[0-9a-f]+$|^unknown$` before use | a89d741 |
| 4 | Medium | `hats link` / `hats unlink` accepted unvalidated resource names (`../foo`, `*`, `.`, `..`) | Added `_validate_resource` that enforces `^\.?[a-zA-Z0-9][a-zA-Z0-9._-]*$` — same constraint as account names | a89d741 |

**Informational (no action):**
- Credentials never written to stdout or command lines — `OPENAI_API_KEY` is
  piped via stdin, not argv
- `chmod 600` consistently applied across credential-file creation paths
- Smoke-test sandbox override of `$HOME` + `$HATS_DIR` correctly isolates
  tests from the host's real config

**Regression coverage:** `tests/smoke.sh` includes assertions for the
`_validate_resource` and `--no-color` paths; CI runs the suite on
`ubuntu-latest` + `macos-latest` on every push.

**Not yet addressed:**
- Plaintext-on-disk for credentials (see "What's NOT Protected" above) —
  matches upstream claude-code behavior, not hats-specific
- Symlink-target validation for non-isolated shared resources — `hats
  doctor` section 2c flags orphan isolated resources in `base/` as WARN but
  does not verify that shared symlinks resolve inside `$HATS_DIR`

## Reporting Vulnerabilities

If you discover a security issue in hats, please open a GitHub issue or contact the maintainer directly. hats is a simple shell script — the attack surface is small and all code is auditable in a single file.
