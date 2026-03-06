# hats

![hats — Switch between Claude Code accounts like changing hats](banner.png)

Switch between Claude Code accounts like changing hats.

Run multiple Claude Code subscriptions on the same machine — including concurrently — with per-account config directory isolation and flexible resource sharing.

## Why

Claude Code stores credentials at `~/.claude/.credentials.json` — one file, one account. If you have multiple subscriptions (personal, work, team), switching accounts means swapping credentials. Running concurrent sessions is even harder.

**hats** solves this by giving each account its own `CLAUDE_CONFIG_DIR`:
- Each account gets an isolated config directory with its own credentials
- Concurrent sessions are inherently safe — no file swapping, no locking, no races
- Shared resources (settings, hooks, MCP config, CLAUDE.md) are symlinked to a `base/` template
- Any resource can be selectively isolated per account with `hats unlink`
- Shell functions let you type the account name as a command

## Quick Start

```bash
# Install
git clone https://github.com/CommanderCrowCode/hats.git
cd hats && ./install.sh

# Initialize (migrates existing ~/.claude/ if present)
hats init

# Create accounts (opens claude for /login authentication)
hats add work
hats add personal

# Set your default (bare `claude` runs as this account)
hats default work

# Use it
hats swap personal              # starts claude as "personal"
hats swap work -- --model opus  # pass flags to claude

# Or add shell functions to your .zshrc/.bashrc
eval "$(hats shell-init)"
personal                        # just type the account name
work --model opus               # with arguments
```

## Install

```bash
git clone https://github.com/CommanderCrowCode/hats.git
cd hats
./install.sh
```

This copies `hats` to `~/.local/bin/`. Make sure `~/.local/bin` is in your `PATH`.

### Requirements

- Linux or macOS (no platform-specific dependencies)
- `python3` (for token inspection)
- Claude Code installed (`claude` on PATH)

## How It Works

### Per-Account Config Directories

Each account gets its own complete `CLAUDE_CONFIG_DIR`:

```
~/.hats/
├── config.toml                      # default account, version
├── claude/
│   ├── base/                        # template (shared resources)
│   │   ├── settings.json
│   │   ├── hooks.json
│   │   ├── .mcp.json
│   │   ├── CLAUDE.md
│   │   ├── projects/
│   │   └── ...
│   ├── work/                        # CLAUDE_CONFIG_DIR for "work"
│   │   ├── .credentials.json        # isolated (own tokens)
│   │   ├── .claude.json             # isolated (own state)
│   │   ├── settings.json  →         ../base/settings.json
│   │   ├── CLAUDE.md      →         ../base/CLAUDE.md
│   │   └── ...            →         ../base/...
│   └── personal/                    # CLAUDE_CONFIG_DIR for "personal"
│       └── (same structure)

~/.claude → ~/.hats/claude/work/     # symlink to default account
```

Running an account is simply:
```bash
CLAUDE_CONFIG_DIR=~/.hats/claude/work claude "$@"
```

No credential swapping. No locking. No save-back. Claude Code reads and writes directly to the account's own directory.

### Resource Sharing

By default, everything except credentials and state is symlinked to `base/`:
- **Always isolated**: `.credentials.json`, `.claude.json` (per-account tokens and identity)
- **Shared by default**: `settings.json`, `hooks.json`, `.mcp.json`, `CLAUDE.md`, `projects/`, etc.

Selectively isolate any resource:
```bash
hats unlink personal CLAUDE.md    # personal gets its own CLAUDE.md
hats link personal CLAUDE.md      # re-share with base
hats status personal              # see what's linked vs isolated
```

### Concurrency

Concurrent sessions are inherently safe. Each account has its own directory — sessions never touch each other's files. Token refresh writes to the correct account's `.credentials.json` automatically.

### Token Lifecycle

| Component | Lifetime | Renewal |
|-----------|----------|---------|
| Access token | ~8 hours | Auto-refreshed by Claude Code |
| Refresh token | Months | Re-run `/login` when it expires |

## Commands

### Account Management

```bash
hats init              # Initialize, migrate from ~/.claude/ if exists
hats add <name>        # Create account (opens claude for /login)
hats remove <name>     # Remove an account
hats default [name]    # Get or set default account
hats list              # Show all accounts with token status
```

### Session Management

```bash
hats swap <name> [-- claude-args...]
```

Runs `claude` with the account's `CLAUDE_CONFIG_DIR`.

```bash
hats swap work                        # interactive session
hats swap work -- --model opus        # pass flags to claude
hats swap work -- -p "hello"          # print mode
```

### Resource Management

```bash
hats link <acct> <file>     # Share a resource with base (symlink)
hats unlink <acct> <file>   # Isolate a resource (copy from base)
hats status [account]       # Show linked vs isolated resources
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
work() { CLAUDE_CONFIG_DIR="$HOME/.hats/claude/work" claude "$@"; }
personal() { CLAUDE_CONFIG_DIR="$HOME/.hats/claude/personal" claude "$@"; }
```

### Maintenance

```bash
hats fix               # Repair broken symlinks, verify auth
hats version           # Show version
```

## Adding a New Account

```bash
hats add myaccount
# Claude Code opens — run /login, authenticate, then /exit
```

That's it. The account directory is created with symlinks to base, and `/login` stores credentials in the isolated directory.

## Remote Control

Claude Code's [Remote Control](https://docs.anthropic.com/en/docs/claude-code/remote-control) feature requires the `user:sessions:claude_code` OAuth scope, which is only granted by the full `/login` flow.

`hats list` shows `[rc]` for accounts with Remote Control support and `[no-rc]` for those without.

## Status Output

```
$ hats list
hats v1.0.0 — Claude Code Accounts
=======================================

  * work         ok (expires 2026-03-07 14:30) [rc]
    personal     ok (access expired, will auto-refresh) [rc]
    team         ok (expires 2026-03-06 22:15) [no-rc]

  3 account(s)
```

- `*` marks the default account
- `[rc]` = Remote Control supported
- Access tokens expire every ~8 hours but auto-refresh via the refresh token

## Configuration

| Variable | Default | Purpose |
|----------|---------|---------|
| `HATS_DIR` | `~/.hats` | Hats root directory |

### File Layout

```
~/.hats/
├── config.toml                       # Global config (default account)
├── claude/
│   ├── base/                         # Template (never run directly)
│   │   ├── settings.json             # Shared settings
│   │   ├── CLAUDE.md                 # Shared instructions
│   │   ├── projects/                 # Shared project data
│   │   └── ...
│   ├── <account>/                    # Per-account config directory
│   │   ├── .credentials.json         # Isolated credentials
│   │   ├── .claude.json              # Isolated state
│   │   └── (everything else)  →      ../base/...

~/.claude → ~/.hats/claude/<default>/ # Symlink so bare `claude` works
```

## Migrating from v0.2.x

`hats init` automatically detects and migrates v0.2.x setups:

1. Moves `~/.claude/` contents to `~/.hats/claude/base/`
2. Creates per-account directories from existing `.credentials.<name>.json` files
3. Symlinks `~/.claude` to the default account
4. Preserves external symlinks (CLAUDE.md, agents, skills)

## Troubleshooting

**Auth errors after idle:**
The refresh token may have expired. Run `/login` inside a session for that account.

**Wrong identity showing:**
Each account has its own `.claude.json` state. Run `hats fix` to verify symlinks, or start a fresh session.

**Broken symlinks after Claude Code update:**
Run `hats fix` — it detects broken symlinks and repairs them, and adds symlinks for new resources added to base.

## License

MIT
