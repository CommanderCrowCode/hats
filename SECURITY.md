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

## Reporting Vulnerabilities

If you discover a security issue in hats, please open a GitHub issue or contact the maintainer directly. hats is a simple shell script — the attack surface is small and all code is auditable in a single file.
