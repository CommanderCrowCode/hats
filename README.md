# hats

![hats — Switch between Claude Code accounts like changing hats](banner.png)

Switch between Claude Code accounts like changing hats.

Run multiple Claude Code subscriptions on the same machine with safe credential swapping, `flock`-based concurrency, and built-in backup/restore.

## Why

Claude Code stores credentials at `~/.claude/.credentials.json` — one file, one account. If you have multiple subscriptions (personal, work, team), you need to swap credentials before starting each session.

**hats** automates this with:
- Named accounts discovered from credential files
- `flock`-serialized swaps (safe for concurrent sessions)
- Automatic restore of your default account on session exit
- Vault backups for disaster recovery
- Shell functions so each account is just a command

## Quick Start

```bash
# Install
git clone https://github.com/CommanderCrowCode/hats.git
cd hats && ./install.sh

# Initialize (detects existing credential files)
hats init

# Save your current credentials as a named account
hats add work

# Log in as a second account
hats stash
claude              # run /login in the browser as your other account
hats add personal
hats unstash

# Set your default (restored after every session)
hats default work

# Use it
hats swap personal              # starts claude as "personal"
hats swap work remote-control   # starts remote-control as "work"

# Or add shell functions to your .zshrc/.bashrc
eval "$(hats shell-init)"
personal                        # just type the account name
work remote-control             # with arguments
```

## Install

```bash
git clone https://github.com/CommanderCrowCode/hats.git
cd hats
./install.sh
```

This copies `hats` to `~/.local/bin/`. Make sure `~/.local/bin` is in your `PATH`.

Or manually:
```bash
cp hats ~/.local/bin/hats
chmod +x ~/.local/bin/hats
```

### Requirements

- Linux (uses `flock` from `util-linux`)
- `python3` (for token inspection)
- Claude Code installed (`claude` on PATH)

macOS: `flock` is not available by default. Install via `brew install util-linux` or use the [flock shim](https://github.com/discoteq/flock).

## How It Works

### Credential Swap

```
1. flock acquires exclusive lock
2. cp account's credentials → ~/.claude/.credentials.json
3. flock releases lock
4. claude starts, reads credentials into memory
5. claude runs (credentials in memory, file on disk doesn't matter)
6. claude exits
7. flock acquires lock
8. cp default account's credentials → ~/.claude/.credentials.json
9. flock releases lock
```

### Concurrency

The lock is held only for the duration of a `cp` (microseconds). Multiple sessions run simultaneously — once Claude starts, credentials are in memory. The only theoretical race is two sessions starting within microseconds of each other, which can't happen with manual starts.

### Token Lifecycle

| Component | Lifetime | Renewal |
|-----------|----------|---------|
| Access token | ~8 hours | Auto-refreshed by Claude Code |
| Refresh token | Months | Re-run `/login` when it expires |

Claude Code handles access token refresh automatically. No manual intervention needed unless the refresh token expires (you'll see auth errors).

## Commands

### Account Management

```bash
hats init              # Initialize, detect existing accounts
hats add <name>        # Save current credentials as named account
hats remove <name>     # Remove an account
hats default [name]    # Get or set default account
hats list              # Show all accounts with token status
```

### Session Management

```bash
hats swap <name> [-- claude-args...]
```

Swaps credentials, runs `claude` with any provided arguments, restores default on exit.

```bash
hats swap work                        # interactive session
hats swap work remote-control         # remote control session
hats swap work -- --model opus        # pass flags to claude
```

### Credential Safety

```bash
hats backup            # Backup all credentials to vault
hats restore [name]    # Restore from vault
hats stash             # Temporarily set aside active credentials
hats unstash           # Restore stashed credentials
hats fix               # Repair corrupted state, clear locks
```

### Shell Integration

```bash
# Add to .zshrc or .bashrc:
eval "$(hats shell-init)"

# With auto-skip permissions:
eval "$(hats shell-init --skip-permissions)"
```

This generates a function for each account:
```bash
work() { hats swap work -- "$@"; }
personal() { hats swap personal -- "$@"; }
```

So you can just type `work` or `personal remote-control`.

## Adding a New Account

```bash
# 1. Stash current credentials
hats stash

# 2. Start claude with no credentials (triggers login)
claude
# Run /login in the prompt
# Authenticate as the new account in your browser
# Type /exit after login completes

# 3. Save the new credentials
hats add <name>

# 4. Restore your previous credentials
hats unstash

# 5. Back up everything
hats backup
```

## Remote Control

Claude Code's [Remote Control](https://docs.anthropic.com/en/docs/claude-code/remote-control) feature requires the `user:sessions:claude_code` OAuth scope. This scope is only granted by the full `/login` flow — NOT by `setup-token`.

```
# setup-token scopes (insufficient):
['user:inference']

# /login scopes (includes remote-control):
['user:inference', 'user:mcp_servers', 'user:profile', 'user:sessions:claude_code']
```

`hats list` shows `[rc]` for accounts with Remote Control support and `[no-rc]` for those without.

## Status Output

```
$ hats list
Claude Code Accounts (hats 0.2.0)
======================================

  * work         ok (expires 2026-02-26) [rc] [vault]
    personal     ok (access expired, will auto-refresh) [rc] [vault]
    team         ok (expires 2026-02-25) [no-rc]

Lock: none
```

- `*` marks the default account
- `[rc]` = Remote Control supported
- `[vault]` = vault backup exists
- Access tokens expire every ~8 hours but auto-refresh via the refresh token

## Configuration

hats uses environment variables for configuration:

| Variable | Default | Purpose |
|----------|---------|---------|
| `HATS_CLAUDE_DIR` | `~/.claude` | Claude Code config directory |
| `HATS_CONFIG_DIR` | `~/.config/hats` | Hats config and vault directory |

### File Layout

```
~/.claude.json                        # Claude Code state (contains cached identity)

~/.claude/
├── .credentials.json                 # Active credentials (always default when idle)
├── .credentials.<account>.json       # Per-account permanent credentials
├── .profile.<account>.json           # Per-account cached identity (name, email)
└── .credentials.lock                 # flock lockfile (auto-created)

~/.config/hats/
├── default                           # Default account name
└── vault/
    ├── .credentials.<account>.json   # Credential backup
    └── .profile.<account>.json       # Identity backup
```

## Troubleshooting

**"Lock timeout" error:**
A previous session crashed during a swap. Run `hats fix` to clear the lock.

**Wrong account in session:**
Extremely rare — credentials were swapped between lock release and claude reading the file. Restart the session.

**Auth errors after idle:**
The refresh token may have expired. Re-run `/login` for that account.

**"flock: command not found":**
Install `util-linux` (Linux) or see macOS instructions above.

**tmux quits when running account function:**
Never use `exec N>file` fd syntax in zsh — it kills the shell. hats uses the safe `flock FILE COMMAND ARGS` form.

## License

MIT
