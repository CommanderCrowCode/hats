# Security

## Threat Model

hats manages Claude Code OAuth credentials on a local machine. The primary security concerns are:

1. **Credential confidentiality** — preventing unauthorized access to tokens
2. **Credential integrity** — preventing corruption during swaps
3. **Session isolation** — ensuring the right credentials reach the right session

## Current Security (v0.1)

### What's Protected

**File permissions:** All credential files are created with `chmod 600` (owner read/write only). No group or world access.

**Atomic swaps:** `flock` serializes credential file writes. No partial writes, no torn reads between concurrent sessions.

**Environment cleanup:** `CLAUDE_CODE_OAUTH_TOKEN` is unset before starting claude to prevent stale env vars from overriding file-based auth. tmux environment is also cleaned.

**No network exposure:** hats never transmits credentials. All operations are local file copies.

**Vault backups:** Separate backup copies allow recovery from accidental deletion or corruption.

### What's NOT Protected

**Plaintext on disk:** Credential files (access tokens + refresh tokens) are stored as plaintext JSON. Any process running as your user can read them. This is the same security model as Claude Code itself — hats doesn't make it worse, but doesn't improve it either.

**No encryption at rest:** The vault backups are also plaintext. If an attacker has read access to your home directory, they can read all credentials.

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
- Ensure `~/.claude/` and `~/.config/hats/` are not world-readable
- Use full-disk encryption
- Consider running each account in a separate OS user
- Monitor `~/.claude/.credentials.json` for unexpected access (inotifywait, auditd)

### General

- Never commit credential files to git (`.gitignore` handles this for the hats repo)
- Regularly run `hats backup` — vault copies survive accidental `rm`
- If you suspect a token is compromised, revoke it at [console.anthropic.com](https://console.anthropic.com) and re-run `/login`

## Reporting Vulnerabilities

If you discover a security issue in hats, please open a GitHub issue or contact the maintainer directly. hats is a simple shell script — the attack surface is small and all code is auditable in a single file.
