# Roadmap

## v0.1

Plaintext credential files with flock-based swapping.

- [x] Named account management (add, remove, list)
- [x] flock-serialized credential swaps
- [x] Automatic default account restore on exit
- [x] Vault backup/restore
- [x] Token status inspection (expiry, refresh, remote-control scope)
- [x] Shell integration (shell-init)
- [x] Stash/unstash for adding new accounts
- [x] Configurable via environment variables

## v0.2

Identity-aware account switching.

- [x] Profile identity swap — save/restore cached user identity (displayName, email) per account
- [x] Save refreshed tokens back to account file after swap session
- [x] `./bump <major|minor|patch>` dev script for semantic versioning
- [x] Credential & profile contamination detection in `hats fix`

## v1.0 (Current)

Per-account `CLAUDE_CONFIG_DIR` isolation — complete architecture rewrite.

- [x] Each account gets its own config directory (no more credential swapping)
- [x] Concurrent sessions are inherently safe (no locking, no races)
- [x] `base/` template directory with shared resources via symlinks
- [x] `hats link` / `hats unlink` — selectively share or isolate any resource
- [x] `hats status` — show linked vs isolated resources per account
- [x] Automatic migration from v0.2.x via `hats init`
- [x] `~/.claude` symlink to default account (bare `claude` still works)
- [x] No `flock` dependency — works on macOS and Linux without extra packages
- [x] Provider-scoped directory structure (`~/.hats/claude/`) for future expansion

### Removed (no longer needed)

- Credential file swapping and flock locking
- Save-back logic (was root cause of credential corruption)
- Profile save/restore (each account has own `.claude.json`)
- Stash/unstash (accounts have isolated directories)
- Vault backup/restore (account directories are self-contained)
- Contamination detection (contamination is architecturally impossible)

## v1.1

Quality-of-life improvements.

- [ ] `hats doctor` — comprehensive health check (python3 version, file permissions, symlink integrity)
- [ ] Colored output (with `--no-color` flag)
- [ ] Tab completion for zsh and bash
- [ ] `hats export` / `hats import` — portable credential transfer between machines

## v2.0

Multi-provider support and encrypted storage.

- [ ] Provider abstraction (`~/.hats/cursor/`, `~/.hats/windsurf/`)
- [ ] Encrypted credential backends (age, gpg, OS keychain)
- [ ] `hats encrypt` / `hats decrypt` for credential files

## Future Ideas

- Team credential sharing via encrypted git repos
- Audit logging with timestamps
