# Roadmap

## v0.1 (Current)

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

Quality-of-life improvements.

- [ ] `hats doctor` — comprehensive health check (flock available, python3 version, file permissions)
- [ ] `hats refresh <name>` — guided re-login flow when refresh token expires
- [ ] Colored output (with `--no-color` flag)
- [ ] Tab completion for zsh and bash
- [ ] `hats export` / `hats import` — portable credential transfer between machines

## v1.0

Encrypted credential storage.

- [ ] Encrypted backends for credential files
  - `age` (default) — simple, no daemon, works everywhere
  - `gpg` — for users already using GPG
  - OS keychain — macOS Keychain, GNOME Keyring, KWallet
- [ ] `hats encrypt` — encrypt existing plaintext credentials in place
- [ ] `hats decrypt` — temporary decrypt for debugging
- [ ] Automatic backend detection (prefer encrypted if available, fall back to plaintext)
- [ ] Migration path: `hats upgrade` converts v0.x plaintext to v1.0 encrypted

## Future Ideas

- Multiple CLI tools (not just Claude Code) — generic credential file swapper
- Team credential sharing via encrypted git repos
- Audit logging with timestamps
- macOS native support (replace flock with advisory locks)
