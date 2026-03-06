# Security

## Threat Model

hats manages Claude Code OAuth credentials on a local machine. The primary security concerns are:

1. **Credential confidentiality** — preventing unauthorized access to tokens
2. **Credential integrity** — preventing corruption or cross-contamination
3. **Session isolation** — ensuring the right credentials reach the right session

## Current Security (v1.0)

### What's Protected

**Session isolation:** Each account has its own `CLAUDE_CONFIG_DIR` directory. Claude Code reads and writes credentials, state, and cache files in complete isolation. Concurrent sessions never touch each other's files.

**File permissions:** All credential files are created with `chmod 600` (owner read/write only). No group or world access.

**No credential swapping:** Unlike v0.2.x, credentials are never copied between files. Each account's `.credentials.json` is written to directly by Claude Code. This eliminates the entire class of save-back corruption bugs.

**No shared mutable state:** Each account has its own `.claude.json` state file, eliminating profile contamination across accounts.

**Environment cleanup:** `CLAUDE_CODE_OAUTH_TOKEN` is not used. Each session is scoped by `CLAUDE_CONFIG_DIR` only.

**No network exposure:** hats never transmits credentials. All operations are local file and symlink management.

### What's NOT Protected

**Plaintext on disk:** Credential files (access tokens + refresh tokens) are stored as plaintext JSON. Any process running as your user can read them. This is the same security model as Claude Code itself — hats doesn't make it worse, but doesn't improve it either.

**Symlinked shared resources:** Settings, hooks, and MCP config are shared across accounts via symlinks by default. A compromised account's session could modify shared settings. Use `hats unlink` to isolate sensitive config per account.

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

## Reporting Vulnerabilities

If you discover a security issue in hats, please open a GitHub issue or contact the maintainer directly. hats is a simple shell script — the attack surface is small and all code is auditable in a single file.
