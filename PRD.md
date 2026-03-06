# Product Requirements Document: hats v1.0

Version: 1.0
Date: 2026-03-06
Author: PRD-engineer Agent
Status: Draft
Location: /home/tanwa/hats/PRD.md

---

## Executive Summary

hats v1.0 is a complete rewrite of the multi-account CLI tool for Claude Code. The current v0.2.x architecture stores all account credentials as sibling files in a shared `~/.claude/` directory and swaps the active `.credentials.json` file under `flock` before launching Claude Code. This design has fundamental flaws: race conditions between concurrent sessions, credential corruption from save-back logic, profile contamination across accounts, and a growing pile of defensive workarounds (v0.2.1 through v0.2.3 are all bug fixes for these systemic issues).

v1.0 eliminates the entire class of credential-swapping bugs by giving each account its own complete `CLAUDE_CONFIG_DIR` directory. Claude Code's `CLAUDE_CONFIG_DIR` environment variable is set to point at the account's directory, so Claude reads and writes credentials, state, and cache files in isolation. No file swapping, no locking, no save-back, no contamination. Concurrent sessions are inherently safe because they never touch each other's files.

The new architecture introduces a `base/` template directory that holds shared resources (settings, hooks, MCP config, CLAUDE.md, agents, skills, etc.) which account directories symlink to. Users can selectively `unlink` any resource to make it account-specific, or `link` it back to shared. The migration from v0.2.x is handled by `hats init`, which restructures `~/.claude/` into the new `~/.hats/` layout and creates a backwards-compatible symlink so bare `claude` continues to work.

## Problem Statement

### User Problems
- **Race conditions on concurrent sessions**: Two `hats swap` calls starting near-simultaneously can read each other's credentials because the swap window (copy + launch) is not atomic relative to Claude's file read
- **Credential corruption**: The save-back logic (copying refreshed tokens back to the account file after Claude exits) can overwrite valid credentials with stale or failed-auth data
- **Profile contamination**: The cached identity in `~/.claude.json` is shared across all accounts, causing wrong-user displays and requiring defensive save/restore logic
- **Growing complexity**: v0.2.1, v0.2.2, and v0.2.3 are all bug fixes for the credential-swapping architecture. Each fix adds more edge-case handling without fixing the root cause
- **No shared config management**: Users who want the same `settings.json` or `CLAUDE.md` across accounts must manually keep them in sync
- **flock dependency**: The `flock` requirement breaks macOS compatibility and adds unnecessary complexity

### Business Impact
- Users with multiple Claude Code subscriptions cannot safely run concurrent sessions, limiting productivity
- The credential corruption bugs erode trust in the tool — users discover auth failures hours after the corruption happened
- macOS users cannot use hats at all without installing third-party `flock`
- The fragile architecture discourages contributors and makes the codebase harder to maintain

## Codebase Investigation Results

### Automated Analysis Summary

#### Architecture Findings
- **Pattern**: Single-file bash script (780 lines), self-contained with `{ }` guard for atomic script loading
- **Entry Point**: `/home/tanwa/hats/hats:720` — `case` statement routing commands
- **Core Modules**: Helper functions (lines 22-179), command implementations (lines 182-717)
- **Script Guard**: Lines 8-11 — `{ }` block ensures the entire script is read into memory before execution, protecting against mid-session upgrades

#### Existing Related Features
- **Credential management**: `_creds_file()` at line 23, `_accounts()` at line 26 — file-naming convention for per-account credentials
- **Profile management**: `_save_profile()` at line 68, `_restore_profile()` at line 87 — identity swap logic (will be eliminated in v1.0)
- **Shell integration**: `cmd_shell_init()` at line 694 — generates shell functions per account (pattern to preserve)
- **Token inspection**: `_token_info()` at line 43 — python3-based token parsing (reuse as-is)
- **Install script**: `/home/tanwa/hats/install.sh` — atomic install via temp file + mv (pattern to preserve)
- **Version bump**: `/home/tanwa/hats/bump` — sed-based version update (reuse as-is)

#### Technical Landscape
- **Tech Stack**: Bash (set -euo pipefail), Python3 (JSON parsing only), coreutils
- **Data Layer**: Flat JSON files with `chmod 600` permissions
- **External Dependencies**: `flock` (util-linux) for locking, `python3` for JSON, `claude` CLI
- **Testing Infrastructure**: None implemented. Test plan exists at `/home/tanwa/hats/TEST_PLAN.md` describing BATS-core framework (133 planned tests, zero written)

#### Discovered Constraints
- **Existing symlinks in ~/.claude/**: User has `agents`, `skills`, and `CLAUDE.md` symlinked to external paths (`/home/tanwa/opt/scripts/`) — migration MUST preserve these
- **~/.claude.json state file**: Lives OUTSIDE `~/.claude/` at `~/.claude.json` — but with `CLAUDE_CONFIG_DIR`, Claude Code uses `$CLAUDE_CONFIG_DIR/.claude.json` instead, which eliminates the shared-state problem
- **Large directories**: `session-env/` (282 entries), `file-history/` (72 entries), `debug/` (73K) — these should be symlinked to base, not copied per account
- **Existing accounts**: User has 3 accounts (shannon, monet, debussy) that need migration
- **Security warnings state files**: Multiple `security_warnings_state_*.json` files in `~/.claude/` — should be treated as shared resources

#### Technical Debt Being Eliminated
- **flock dependency**: Lines 126-131, 389-393, 408, 424 — entire locking mechanism is unnecessary with per-directory isolation
- **Save-back logic**: Lines 407-409 — token refresh save-back is the root cause of credential corruption
- **Profile swap**: Lines 68-119 — profile save/restore is a workaround for shared state file
- **Credential contamination detection**: Lines 541-598 — the `hats fix` contamination detector is a symptom of the architecture, not a feature
- **Stash/unstash commands**: Lines 670-692 — workaround for adding new accounts; unnecessary when each account has its own directory

## Proposed Solution

### Overview

Replace the credential-swapping architecture with per-account `CLAUDE_CONFIG_DIR` directories. Each account gets a complete Claude configuration directory with its own credentials and state. Shared resources (settings, hooks, etc.) are symlinked to a `base/` template directory. Running an account is simply `CLAUDE_CONFIG_DIR=~/.hats/claude/<name> claude "$@"` — no swapping, no locking, no save-back.

### User Stories

1. As a multi-account user, I want to run concurrent Claude Code sessions under different accounts so that I can work on multiple projects simultaneously without credential conflicts
2. As a user, I want my settings, hooks, and MCP config shared across all accounts so that I only configure them once
3. As a user, I want to selectively isolate specific config files per account (e.g., different CLAUDE.md for work vs personal) so that I can customize per-account behavior
4. As a user, I want `hats init` to migrate my existing v0.2.x setup so that I don't lose my accounts or configuration
5. As a user, I want bare `claude` to work as my default account so that my workflow is unchanged
6. As a macOS user, I want hats to work without `flock` so that I can use the tool without third-party dependencies
7. As a user, I want to see which resources are linked (shared) vs isolated per account so that I understand my configuration
8. As a user, I want to add a new account by simply running `hats add <name>` which triggers `claude auth login` in the new account's isolated directory

### Success Criteria

- [ ] Zero credential corruption in concurrent sessions (inherent from architecture)
- [ ] All existing v0.2.x accounts migrated successfully via `hats init`
- [ ] Bare `claude` command works as default account via `~/.claude` symlink
- [ ] No `flock` dependency — works on macOS and Linux without extra packages
- [ ] All shared resources properly symlinked, credentials properly isolated
- [ ] Shell integration (`hats shell-init`) generates working account functions
- [ ] `hats link` / `hats unlink` correctly toggle resource sharing
- [ ] Token inspection (`hats list`) shows auth status for all accounts
- [ ] Existing symlinks in `~/.claude/` (agents, skills, CLAUDE.md pointing to external paths) preserved through migration
- [ ] File permissions (600) maintained on credential files

## Technical Specification

### Implementation Approach

Complete rewrite of the `hats` script. The `{ }` guard pattern from line 8-11 is preserved. Python3 usage for JSON parsing is preserved. The `_token_info()` function is reused with minimal changes. Everything else is new.

#### Directory Layout

```
~/.hats/
├── config.toml                      # global hats config (default account, provider settings)
├── claude/
│   ├── base/                        # template — never run directly
│   │   ├── settings.json
│   │   ├── hooks.json
│   │   ├── .mcp.json
│   │   ├── CLAUDE.md        →       /home/tanwa/opt/scripts/CLAUDE.md  (external symlink preserved)
│   │   ├── agents           →       /home/tanwa/opt/scripts/claude-agents (external symlink preserved)
│   │   ├── skills           →       /home/tanwa/opt/scripts/claude/skills (external symlink preserved)
│   │   ├── projects/
│   │   ├── plugins/
│   │   ├── debug/
│   │   ├── session-env/
│   │   ├── shell-snapshots/
│   │   ├── file-history/
│   │   ├── downloads/
│   │   ├── cache/
│   │   ├── hooks/
│   │   ├── stats-cache.json
│   │   └── ...everything else from ~/.claude/
│   ├── shannon/                     # runnable account
│   │   ├── .credentials.json        # ISOLATED (own copy)
│   │   ├── .claude.json             # ISOLATED (own copy)
│   │   ├── settings.json   →       ../base/settings.json
│   │   ├── hooks.json       →       ../base/hooks.json
│   │   ├── .mcp.json        →       ../base/.mcp.json
│   │   ├── CLAUDE.md        →       ../base/CLAUDE.md
│   │   ├── agents           →       ../base/agents
│   │   ├── skills           →       ../base/skills
│   │   ├── projects         →       ../base/projects
│   │   └── ...all other resources → ../base/...
│   ├── monet/                       # same structure
│   └── debussy/                     # same structure
```

#### How Running Works

```bash
# hats swap shannon -- --model opus
CLAUDE_CONFIG_DIR="$HOME/.hats/claude/shannon" claude --model opus

# Shell function generated by shell-init:
shannon() { CLAUDE_CONFIG_DIR="$HOME/.hats/claude/shannon" claude "$@"; }
```

That's it. No credential swapping, no locking, no save-back, no profile restore.

#### How Default Works

```bash
~/.claude → ~/.hats/claude/shannon/   # symlink
```

When user runs bare `claude`, it reads `~/.claude/` which resolves to the default account's directory. Changing the default updates the symlink target.

### Architecture Changes

```
v0.2.x Architecture:
┌──────────────────────────────┐
│ ~/.claude/                   │
│  .credentials.json  (SHARED)│ ← flock swap before launch
│  .credentials.X.json (each) │ ← copy to/from shared on swap
│  .profile.X.json     (each) │ ← save/restore identity
│  settings.json      (SHARED)│
│  CLAUDE.md          (SHARED)│
└──────────────────────────────┘
       ↓ race condition window
    claude reads .credentials.json

v1.0 Architecture:
┌──────────────────────────────┐
│ ~/.hats/claude/              │
│  base/         (template)    │ ← never run directly
│  shannon/      (account)     │ ← CLAUDE_CONFIG_DIR points here
│    .credentials.json (OWN)   │ ← claude reads THIS directly
│    .claude.json      (OWN)   │ ← claude writes THIS directly
│    settings.json → base/     │ ← shared via symlink
│  monet/        (account)     │ ← completely independent
│    .credentials.json (OWN)   │
│    ...                       │
└──────────────────────────────┘
       ↓ no race — each session has own dir
    CLAUDE_CONFIG_DIR=shannon/ claude
```

### New Components

#### 1. Config File Parser (`config.toml`)

- Location: Parsed inline in the `hats` script
- Purpose: Store default account name, provider path prefix
- Format: Simple TOML (parsed with grep/sed, no external dependency)

```toml
[hats]
default = "shannon"

[provider.claude]
path = "~/.hats/claude"
```

#### 2. Resource Management Functions

- `_link_resource()`: Create relative symlink from account dir to base dir for a resource
- `_unlink_resource()`: Copy resource from base (or current symlink target) into account dir, breaking the symlink
- `_is_linked()`: Check if a resource in an account dir is a symlink to base
- `_list_resources()`: Enumerate all resources in base, showing linked/isolated status per account

#### 3. Migration Engine (`cmd_init`)

- Handles v0.2.x to v1.0 migration
- Detects existing `~/.hats/` (idempotent)
- Preserves external symlinks (CLAUDE.md, agents, skills)
- Creates account directories from existing `.credentials.<name>.json` files
- Creates backup before migration

### Commands Specification

#### `hats init`

**Purpose**: First-time setup or migration from v0.2.x

**Flow**:
1. Check if `~/.hats/` already exists (idempotent — report status and exit)
2. Create `~/.hats/claude/base/`
3. Move all contents of `~/.claude/` to `~/.hats/claude/base/` EXCEPT:
   - `.credentials.*.json` files (per-account credentials)
   - `.profile.*.json` files (per-account profiles — v0.2.x only, discarded)
   - `.credentials.json` (active credentials — discarded, replaced by per-account)
   - `.credentials.lock` (flock lock — discarded)
   - `.credentials.json.stash` (stash — discarded with warning)
   - `.credentials.json.bak` (backup — discarded)
   - `.credentials.json.lock` (old lock — discarded)
4. Preserve external symlinks: if `base/CLAUDE.md` is a symlink to an external path, keep it as-is
5. For each `.credentials.<name>.json` found:
   a. Create `~/.hats/claude/<name>/`
   b. Move `.credentials.<name>.json` to `<name>/.credentials.json`
   c. Create empty `.claude.json` in `<name>/` (or extract from `~/.claude.json` if it's the current account)
   d. Create relative symlinks for all other resources: `<name>/settings.json → ../base/settings.json`
   e. Set `chmod 600` on `.credentials.json`
6. Determine default account (from `~/.config/hats/default` if exists, else first account)
7. Create `~/.hats/config.toml` with default
8. Remove `~/.claude/` directory (now empty except discarded files)
9. Create symlink: `~/.claude → ~/.hats/claude/<default>/`
10. Migrate vault: move `~/.config/hats/vault/` to `~/.hats/vault/` (if exists)

**Safety**:
- Create `~/.hats/claude/base.migrating/` first, rename to `base/` on success
- If migration fails mid-way, `~/.claude/` still has original files
- Only remove `~/.claude/` after ALL account directories are created and verified

**Edge cases**:
- No existing accounts: create base from ~/.claude, prompt user to run `hats add <name>`
- ~/.hats already exists: report status, don't modify
- ~/.claude is already a symlink: detect, report, handle (may be from a previous partial migration)

#### `hats add <name>`

**Purpose**: Create a new account directory and authenticate

**Flow**:
1. Validate name (alphanumeric, hyphens, underscores, dots — no path separators)
2. Check `~/.hats/claude/<name>/` doesn't already exist
3. Create `~/.hats/claude/<name>/`
4. Create relative symlinks for all resources in `base/` except `.credentials.json` and `.claude.json`
5. Run `CLAUDE_CONFIG_DIR=~/.hats/claude/<name> claude auth login`
6. Verify `.credentials.json` was created in the account dir
7. Set `chmod 600` on `.credentials.json`
8. If this is the only account, set as default

**Rollback**: If auth login fails or is cancelled, remove the account directory.

#### `hats remove <name>`

**Purpose**: Remove an account directory

**Flow**:
1. Check account exists
2. Warn if it's the default account
3. Confirm removal (unless `--force` flag)
4. Remove `~/.hats/claude/<name>/` directory
5. If was default, clear default (prompt to set new one)

#### `hats list`

**Purpose**: Show all accounts with auth status

**Output format**:
```
hats v1.0 — Claude Code Accounts
=================================

  * shannon      ok (expires 2026-03-07 14:30) [rc]
    monet        ok (access expired, will auto-refresh) [rc]
    debussy      ok (expires 2026-03-06 22:15) [no-rc]

  3 accounts, 0 issues
```

**Implementation**: Iterate `~/.hats/claude/*/`, skip `base/`, read each account's `.credentials.json` using `_token_info()`.

#### `hats default [name]`

**Purpose**: Get or set the default account

**Set flow**:
1. Verify account exists
2. Update `config.toml`
3. Update `~/.claude` symlink: `ln -sfn ~/.hats/claude/<name> ~/.claude`

#### `hats link <account> <resource>`

**Purpose**: Share a resource with base (replace local copy with symlink to base)

**Flow**:
1. Verify account exists and resource exists in base
2. Check resource is not already linked
3. If resource is `.credentials.json` or `.claude.json`, refuse (always isolated)
4. Remove account's local copy of resource
5. Create relative symlink: `<account>/<resource> → ../base/<resource>`

#### `hats unlink <account> <resource>`

**Purpose**: Isolate a resource (copy from base, break symlink)

**Flow**:
1. Verify account exists and resource is currently a symlink to base
2. If resource is `.credentials.json` or `.claude.json`, refuse (already isolated)
3. Resolve the symlink target and copy the actual file/directory
4. Remove the symlink
5. Place the copy in the account directory

#### `hats status [account]`

**Purpose**: Show which resources are linked vs isolated for an account

**Output format**:
```
Account: shannon (default)
Directory: ~/.hats/claude/shannon/

  ISOLATED (account-specific):
    .credentials.json          (always isolated)
    .claude.json               (always isolated)

  LINKED (shared with base):
    settings.json              → ../base/settings.json
    hooks.json                 → ../base/hooks.json
    .mcp.json                  → ../base/.mcp.json
    CLAUDE.md                  → ../base/CLAUDE.md → /home/tanwa/opt/scripts/CLAUDE.md
    agents                     → ../base/agents → /home/tanwa/opt/scripts/claude-agents
    skills                     → ../base/skills → /home/tanwa/opt/scripts/claude/skills
    projects                   → ../base/projects
    plugins                    → ../base/plugins
    ...
```

#### `hats swap <name> [-- claude-args...]`

**Purpose**: Run Claude Code with a specific account's config directory

**Implementation**:
```bash
cmd_swap() {
  local name="$1"; shift
  [ "${1:-}" = "--" ] && shift
  local account_dir="$HATS_DIR/claude/$name"
  [ -d "$account_dir" ] || die "Account '$name' not found."
  [ -f "$account_dir/.credentials.json" ] || die "Account '$name' has no credentials. Run: hats add $name"
  CLAUDE_CONFIG_DIR="$account_dir" claude "$@"
}
```

That's the entire swap implementation. No locking, no save-back, no profile restore.

#### `hats shell-init [--skip-permissions]`

**Purpose**: Output shell functions for each account

**Output**:
```bash
# Generated by hats shell-init
shannon() { CLAUDE_CONFIG_DIR="$HOME/.hats/claude/shannon" claude "$@"; }
monet() { CLAUDE_CONFIG_DIR="$HOME/.hats/claude/monet" claude "$@"; }
debussy() { CLAUDE_CONFIG_DIR="$HOME/.hats/claude/debussy" claude "$@"; }
```

With `--skip-permissions`:
```bash
shannon() { CLAUDE_CONFIG_DIR="$HOME/.hats/claude/shannon" claude --dangerously-skip-permissions "$@"; }
```

#### `hats fix`

**Purpose**: Repair symlinks, verify auth status, detect issues

**Flow**:
1. Verify `~/.hats/` structure exists
2. For each account directory:
   a. Check all expected symlinks point to valid targets in base
   b. Repair broken symlinks (re-create pointing to base)
   c. Verify `.credentials.json` exists and is readable
   d. Check auth status via `_token_info()`
3. Verify `~/.claude` symlink points to default account's directory
4. Report issues found and repairs made

#### `hats version`

**Purpose**: Show version

**Output**: `hats 1.0.0`

### Commands Removed from v0.2.x

| Command | Reason | Alternative in v1.0 |
|---------|--------|---------------------|
| `stash` | Was needed to temporarily remove active creds for new login | `hats add` runs `claude auth login` in isolated dir |
| `unstash` | Counterpart to stash | Not needed |
| `backup` | Vault backup of credential files | Account dirs ARE the backup; use `cp -r` |
| `restore` | Restore from vault | Copy credentials back manually |

The vault system is removed because the per-account directory structure makes credentials self-contained and trivially backed up. A future version could add `hats backup` / `hats restore` as convenience wrappers around `cp -r`.

### Data Models

#### config.toml

```toml
[hats]
version = "1.0.0"
default = "shannon"

[provider.claude]
path = "claude"
# Future: [provider.cursor], [provider.windsurf]
```

Parsed with simple grep/sed — no TOML library needed for this minimal format.

#### Account Directory Contents

Each account directory is a valid `CLAUDE_CONFIG_DIR`:

```
<account>/
├── .credentials.json     # OAuth tokens (chmod 600, NEVER symlinked)
├── .claude.json           # State/identity (NEVER symlinked)
├── settings.json    →     ../base/settings.json     (symlink by default)
├── hooks.json       →     ../base/hooks.json        (symlink by default)
├── .mcp.json        →     ../base/.mcp.json         (symlink by default)
├── CLAUDE.md        →     ../base/CLAUDE.md         (symlink by default)
├── agents           →     ../base/agents            (symlink by default)
├── skills           →     ../base/skills            (symlink by default)
├── projects         →     ../base/projects          (symlink by default)
├── plugins          →     ../base/plugins           (symlink by default)
├── debug            →     ../base/debug             (symlink by default)
├── session-env      →     ../base/session-env       (symlink by default)
├── shell-snapshots  →     ../base/shell-snapshots   (symlink by default)
├── file-history     →     ../base/file-history      (symlink by default)
├── downloads        →     ../base/downloads         (symlink by default)
├── cache            →     ../base/cache             (symlink by default)
├── hooks            →     ../base/hooks             (symlink by default)
├── stats-cache.json →     ../base/stats-cache.json  (symlink by default)
└── (any other base files) → ../base/...             (symlink by default)
```

### API Specifications

Not applicable — hats is a CLI tool, not an API. The "API" is the command-line interface documented above.

### Resources Classification

**Always Isolated** (never symlinked to base):
- `.credentials.json` — OAuth tokens unique per account
- `.claude.json` — runtime state, cached identity, unique per account

**Always Shared** (always symlinked to base by default, can be unlinked):
- Everything else in the directory

**Cannot Be Linked/Unlinked** (always isolated, `hats link` refuses):
- `.credentials.json`
- `.claude.json`

## Implementation Plan & Progress Tracking

### Phase 1: Core Infrastructure (Foundation)

- [ ] ⏳ **1.1** Define constants and directory structure
  - `HATS_DIR="${HATS_DIR:-$HOME/.hats}"`
  - `HATS_CLAUDE_DIR="$HATS_DIR/claude"`
  - `HATS_BASE_DIR="$HATS_CLAUDE_DIR/base"`
  - `HATS_CONFIG="$HATS_DIR/config.toml"`
  - `ALWAYS_ISOLATED=(".credentials.json" ".claude.json")`
  - Status: Not started
  - Notes: Preserve `{ }` guard from current script (line 8-11)

- [ ] ⏳ **1.2** Implement config.toml parser
  - `_config_get <section> <key>` — grep-based TOML value extraction
  - `_config_set <section> <key> <value>` — sed-based TOML value update
  - `_default_account` — read from config.toml
  - Status: Not started
  - Notes: Keep it simple — no nested tables, no arrays, just `key = "value"` under `[section]`

- [ ] ⏳ **1.3** Implement account enumeration
  - `_accounts` — list directories in `$HATS_CLAUDE_DIR/` excluding `base/`
  - `_account_dir <name>` — return path to account directory
  - `_account_exists <name>` — check if account directory exists
  - `_validate_name <name>` — check name format (alphanumeric, hyphens, underscores, dots)
  - Status: Not started
  - Notes:

- [ ] ⏳ **1.4** Preserve `_token_info()` function
  - Copy from current `hats:43-66` with minimal changes
  - Update file path references for new directory structure
  - Status: Not started
  - Notes: This function is stable and well-tested by usage

- [ ] ⏳ **1.5** Implement `_show_account_status()`
  - Adapt from current `hats:133-179`
  - Remove vault marker (vault system removed)
  - Add directory path in verbose mode
  - Status: Not started
  - Notes:

### Phase 2: Resource Management (Symlink Engine)

- [ ] ⏳ **2.1** Implement `_link_resource <account> <resource>`
  - Refuse if resource is in ALWAYS_ISOLATED list
  - Remove local copy, create relative symlink to `../base/<resource>`
  - Handle both files and directories
  - Status: Not started
  - Notes: Use `ln -sfn` for atomic symlink creation

- [ ] ⏳ **2.2** Implement `_unlink_resource <account> <resource>`
  - Refuse if resource is in ALWAYS_ISOLATED list
  - Verify resource is currently a symlink to base
  - Resolve symlink, copy target content to account dir
  - Remove symlink, place copy
  - Handle both files and directories (`cp -a` for dirs)
  - Status: Not started
  - Notes:

- [ ] ⏳ **2.3** Implement `_is_linked <account> <resource>`
  - Check if resource in account dir is a symlink pointing to `../base/<resource>`
  - Return 0 (true) or 1 (false)
  - Status: Not started
  - Notes:

- [ ] ⏳ **2.4** Implement `_setup_account_dir <name>`
  - Create account directory
  - Enumerate all files/dirs in base/ excluding ALWAYS_ISOLATED
  - Create relative symlinks for each
  - Create empty `.claude.json`
  - Status: Not started
  - Notes: This is used by both `hats add` and `hats init` migration

### Phase 3: Core Commands

- [ ] ⏳ **3.1** Implement `cmd_swap`
  - ~5 lines: validate account, set CLAUDE_CONFIG_DIR, exec claude
  - No locking, no save-back, no profile management
  - Status: Not started
  - Notes: This is the simplest it can possibly be

- [ ] ⏳ **3.2** Implement `cmd_add`
  - Create account dir via `_setup_account_dir`
  - Run `CLAUDE_CONFIG_DIR=<account_dir> claude auth login`
  - Verify credentials created
  - Rollback on failure
  - Status: Not started
  - Notes:

- [ ] ⏳ **3.3** Implement `cmd_remove`
  - Validate, warn if default, remove directory
  - Status: Not started
  - Notes: Consider `--force` flag to skip confirmation

- [ ] ⏳ **3.4** Implement `cmd_list`
  - Iterate account directories, show status
  - Status: Not started
  - Notes:

- [ ] ⏳ **3.5** Implement `cmd_default`
  - Get: read from config.toml
  - Set: update config.toml, update `~/.claude` symlink
  - Status: Not started
  - Notes:

- [ ] ⏳ **3.6** Implement `cmd_link` and `cmd_unlink`
  - Thin wrappers around `_link_resource` and `_unlink_resource`
  - Status: Not started
  - Notes:

- [ ] ⏳ **3.7** Implement `cmd_status`
  - Enumerate resources, show linked vs isolated
  - Show symlink chain for external symlinks (e.g., CLAUDE.md → base → external path)
  - Status: Not started
  - Notes:

### Phase 4: Migration and Init

- [ ] ⏳ **4.1** Implement `cmd_init` — fresh setup path
  - No existing `~/.hats/` — create structure from scratch
  - If `~/.claude/` exists, move contents to base
  - Status: Not started
  - Notes:

- [ ] ⏳ **4.2** Implement `cmd_init` — v0.2.x migration path
  - Detect existing `.credentials.<name>.json` files
  - Create account directories with credentials
  - Move remaining files to base
  - Handle external symlinks (agents, skills, CLAUDE.md)
  - Create `~/.claude` → default account symlink
  - Migrate `~/.config/hats/default` to config.toml
  - Status: Not started
  - Notes: This is the most complex command — needs thorough testing

- [ ] ⏳ **4.3** Implement migration safety
  - Atomic directory rename (migrating → final)
  - Verification step before removing old `~/.claude/`
  - Rollback on failure
  - Handle `~/.claude` already being a symlink
  - Status: Not started
  - Notes:

### Phase 5: Shell Integration and Utilities

- [ ] ⏳ **5.1** Implement `cmd_shell_init`
  - Generate `CLAUDE_CONFIG_DIR`-based functions
  - Support `--skip-permissions` flag
  - Status: Not started
  - Notes:

- [ ] ⏳ **5.2** Implement `cmd_fix`
  - Verify symlink integrity per account
  - Repair broken symlinks
  - Verify `~/.claude` symlink
  - Check credential file existence and permissions
  - Status: Not started
  - Notes:

- [ ] ⏳ **5.3** Implement `cmd_version` and help text
  - Update help text for new command set
  - Remove references to stash/unstash/backup/restore/flock
  - Status: Not started
  - Notes:

- [ ] ⏳ **5.4** Update `install.sh`
  - Same atomic install pattern
  - No changes needed unless install path changes
  - Status: Not started
  - Notes:

- [ ] ⏳ **5.5** Update `README.md`
  - New architecture description
  - New command reference
  - Remove flock dependency
  - Add macOS compatibility note (no flock needed)
  - Status: Not started
  - Notes:

### Phase 6: Testing

- [ ] ⏳ **6.1** Update test plan for v1.0 architecture
  - Remove all flock-related tests
  - Remove credential-swapping tests
  - Add symlink management tests
  - Add migration tests
  - Add resource link/unlink tests
  - Status: Not started
  - Notes:

- [ ] ⏳ **6.2** Implement BATS test suite
  - Follow structure from `/home/tanwa/hats/TEST_PLAN.md`
  - Adapt for new architecture
  - Status: Not started
  - Notes:

### Overall Progress
- **Completed Tasks**: 0/20 (0%)
- **In Progress**: 0
- **Blocked**: 0
- **Last Updated**: 2026-03-06 by PRD-engineer

## Testing Strategy

### Test Patterns to Follow
Based on the existing test plan at `/home/tanwa/hats/TEST_PLAN.md`:
- **Framework**: BATS-core (vendored as git submodules)
- **Isolation**: `HATS_DIR` env var per test (temp directory)
- **Mock Strategy**: Mock `claude` binary for auth login simulation

### Test Categories for v1.0

#### Unit Tests: Symlink Engine
- `_link_resource` creates correct relative symlink
- `_link_resource` refuses ALWAYS_ISOLATED resources
- `_unlink_resource` copies content and removes symlink
- `_unlink_resource` handles directories correctly
- `_is_linked` detects symlinks to base vs local files
- `_setup_account_dir` creates all expected symlinks

#### Unit Tests: Config Parser
- `_config_get` reads values from TOML
- `_config_set` updates values in TOML
- `_default_account` falls back correctly

#### Integration Tests: Commands
- `hats add` creates directory, runs auth login, sets up symlinks
- `hats remove` deletes directory, warns on default
- `hats swap` sets CLAUDE_CONFIG_DIR correctly
- `hats default` updates config and symlink
- `hats link` / `hats unlink` toggle resource sharing
- `hats status` shows correct linked/isolated state
- `hats list` shows all accounts with status
- `hats shell-init` generates correct functions

#### Migration Tests
- v0.2.x directory structure migrated correctly
- External symlinks preserved
- Per-account credentials isolated
- Config migrated from `~/.config/hats/`
- Idempotent — running init twice is safe
- Partial migration recovery

#### Regression Tests
- Concurrent sessions don't interfere (each has own dir)
- Token refresh writes to correct account's credentials
- Default account's credentials unchanged when running non-default
- No file locking needed

### Coverage Requirements
- Target: All commands tested, all error paths tested
- Critical paths: migration, swap, add, link/unlink

### QA Testing Requirements
- All success criteria must be tested
- All user stories must have test coverage
- Migration must be tested with real-world directory structures
- Concurrent session safety must be verified

## Risk Assessment

### Technical Risks

| Risk | Evidence | Probability | Impact | Mitigation |
|------|----------|------------|--------|------------|
| Migration corrupts user's ~/.claude | Complex file operations during init | Medium | High | Atomic rename, backup before migration, rollback on failure |
| Claude Code doesn't respect CLAUDE_CONFIG_DIR for all files | Assumption based on env var name | Low | High | Test with actual Claude Code before release; verify .claude.json, credentials, and all config files use CLAUDE_CONFIG_DIR |
| External symlinks break during migration | User has CLAUDE.md, agents, skills symlinked externally (`hats:ls -la ~/.claude` shows this) | Medium | Medium | Detect symlinks in base, preserve them as-is, test with real symlink chains |
| config.toml parsing edge cases | Grep/sed-based parsing is fragile | Low | Low | Keep TOML format minimal, add validation, consider python3 fallback |
| Shared directories cause issues (session-env, debug) | Multiple Claude instances writing to same dirs | Medium | Medium | These are already shared in v0.2.x; monitor for issues, can unlink per-account if needed |
| Users have customized ~/.config/hats/ | v0.2.x stores config there | Low | Low | Migrate during init, preserve old config dir |

### CLAUDE_CONFIG_DIR Verification

**Critical assumption**: Claude Code uses `CLAUDE_CONFIG_DIR` for ALL file access including:
- `.credentials.json` (OAuth tokens)
- `.claude.json` (state, cached identity)
- `settings.json` (user settings)
- All other config files

This MUST be verified before implementation begins. If Claude Code hardcodes `~/.claude/` for any file, the entire architecture needs adjustment.

**Verification steps**:
1. Set `CLAUDE_CONFIG_DIR=/tmp/test-claude`
2. Copy credentials to `/tmp/test-claude/.credentials.json`
3. Run `claude` and verify it reads from the custom dir
4. Verify `.claude.json` is created in the custom dir (not `~/.claude.json`)
5. Verify token refresh writes to the custom dir's credentials

### Identified Technical Debt Being Resolved

| Debt Item | Location | Impact |
|-----------|----------|--------|
| flock-based locking | `hats:126-131, 389-393` | Eliminated — no locking needed |
| Credential save-back | `hats:407-409` | Eliminated — Claude writes directly to account dir |
| Profile save/restore | `hats:68-119` | Eliminated — each account has own .claude.json |
| Contamination detection | `hats:541-598` | Eliminated — contamination impossible with isolated dirs |
| Stash/unstash | `hats:670-692` | Eliminated — `hats add` runs auth login in isolated dir |
| Active credentials file | `hats:14` | Eliminated — no shared credentials file |

## Dependencies and Blockers

### Code Dependencies
- **Internal**: None — single-file script
- **External**: `python3` (JSON parsing), `claude` CLI (auth login, running sessions)

### Removed Dependencies
- `flock` / `util-linux` — no longer needed
- `~/.config/hats/` directory — migrated to `~/.hats/config.toml`

### Infrastructure Dependencies
- `CLAUDE_CONFIG_DIR` environment variable must be respected by Claude Code for ALL file operations (credentials, state, settings)
- Filesystem must support symlinks (all Unix systems do)

### Blockers
- **CRITICAL**: Verify `CLAUDE_CONFIG_DIR` behavior with actual Claude Code before implementing migration. If Claude Code doesn't respect this env var for `.claude.json` (state file), the architecture needs adjustment.

## Recommendations

### Implementation Order
1. **Verify CLAUDE_CONFIG_DIR** — test manually before writing any code
2. **Phase 1-2** — build infrastructure and symlink engine
3. **Phase 3** — core commands (swap first, since it's the simplest and most important)
4. **Phase 4** — migration (most complex, needs thorough testing)
5. **Phase 5** — shell integration and utilities
6. **Phase 6** — testing

### Code Patterns to Preserve from v0.2.x
- `{ }` script guard for atomic loading (`hats:8-11`)
- `set -euo pipefail` (`hats:6`)
- `_token_info()` python3 inline script (`hats:43-66`)
- Atomic install via temp file + mv (`install.sh:11-13`)
- `chmod 600` on credential files throughout

### Code Patterns to Avoid
- Never read/write to `~/.claude/.credentials.json` directly — always use account directory
- Never copy credentials between files — Claude writes directly to the right place
- No `flock` usage — concurrency is handled by directory isolation
- No python3 for anything other than JSON parsing — keep bash-native where possible

### Future Expansion
- Provider scoping (`~/.hats/cursor/`, `~/.hats/windsurf/`) is built into the directory structure
- Encrypted credentials could encrypt `.credentials.json` at rest and decrypt into a tmpfs mount
- `hats backup` / `hats restore` as convenience wrappers around directory copy

## Open Questions

1. **CLAUDE_CONFIG_DIR and .claude.json**: Does Claude Code read/write `.claude.json` from `$CLAUDE_CONFIG_DIR/.claude.json` or always from `~/.claude.json`? This is critical for state isolation.
   - Context: v0.2.x handles this at `hats:16` — the state file is `~/.claude.json` (outside CLAUDE_DIR)
   - Options: If `.claude.json` doesn't respect CLAUDE_CONFIG_DIR, we may need to also set `HOME` or use a wrapper
   - **This must be verified before implementation**

2. **Shared mutable directories**: `session-env/`, `debug/`, `shell-snapshots/`, `file-history/` are large and mutable. Should they be symlinked to base (shared) or isolated per account?
   - Context: Currently shared in v0.2.x (single ~/.claude dir)
   - Recommendation: Start shared (symlinked), allow users to unlink if needed
   - Risk: Concurrent writes to shared dirs could cause issues (but haven't in v0.2.x)

3. **history.jsonl**: This large file (1.3MB) contains conversation history. Should it be shared or per-account?
   - Options: Shared (current behavior), per-account (cleaner separation), or excluded from base
   - Recommendation: Per-account — history should reflect that account's sessions

4. **config.toml vs simpler format**: Is TOML overkill for the minimal config needs? A simple `key=value` file might be simpler to parse.
   - Context: Only need `default` and `provider.path` currently
   - Recommendation: Use TOML for future-proofing (provider scoping), but keep parser minimal

5. **`hats add` auth flow**: Should `hats add` run `claude auth login` or just `claude` (letting the user run `/login` interactively)?
   - Context: `claude auth login` is the direct auth command
   - Recommendation: Use `claude auth login` — it's purpose-built for this

## Appendices

### A. File Reference Map

| v0.2.x Location | v1.0 Location | Notes |
|------------------|---------------|-------|
| `~/.claude/.credentials.json` | `~/.hats/claude/<default>/.credentials.json` (via symlink) | Shared file eliminated |
| `~/.claude/.credentials.<name>.json` | `~/.hats/claude/<name>/.credentials.json` | Per-account, isolated |
| `~/.claude/.profile.<name>.json` | (eliminated) | State in `.claude.json` per account |
| `~/.claude/.credentials.lock` | (eliminated) | No locking needed |
| `~/.claude/settings.json` | `~/.hats/claude/base/settings.json` | Shared via symlinks |
| `~/.claude/CLAUDE.md` | `~/.hats/claude/base/CLAUDE.md` | Shared via symlinks |
| `~/.config/hats/default` | `~/.hats/config.toml` | Consolidated config |
| `~/.config/hats/vault/` | (eliminated or `~/.hats/vault/`) | Vault system simplified |
| `~/.claude.json` | `~/.hats/claude/<account>/.claude.json` | Per-account state (verify CLAUDE_CONFIG_DIR) |

### B. Migration Flowchart

```
~/.claude/ exists?
  ├── No  → Create ~/.hats/claude/base/ (empty), prompt hats add
  └── Yes → Has .credentials.*.json files?
              ├── No  → Move all to base/, prompt hats add
              └── Yes → For each .credentials.<name>.json:
                          1. Create ~/.hats/claude/<name>/
                          2. Move credentials to <name>/.credentials.json
                          3. Symlink everything else to base
                        Move remaining files to base/
                        Set default from ~/.config/hats/default or first account
                        Replace ~/.claude/ with symlink → ~/.hats/claude/<default>/
```

### C. Commands Comparison: v0.2.x vs v1.0

| v0.2.x Command | v1.0 Command | Changes |
|----------------|--------------|---------|
| `hats init` | `hats init` | Complete rewrite — migration engine |
| `hats add <name>` | `hats add <name>` | Creates isolated dir + auth login (was: copy credentials) |
| `hats remove <name>` | `hats remove <name>` | Removes directory (was: remove credential file) |
| `hats list` | `hats list` | Same output, reads from account dirs |
| `hats default [name]` | `hats default [name]` | Also updates ~/.claude symlink |
| `hats swap <name>` | `hats swap <name>` | Sets CLAUDE_CONFIG_DIR (was: copy + flock + save-back) |
| `hats shell-init` | `hats shell-init` | Uses CLAUDE_CONFIG_DIR (was: hats swap wrapper) |
| `hats fix` | `hats fix` | Repairs symlinks (was: repair credentials + locks) |
| `hats backup` | (removed) | Directory-level backup is trivial |
| `hats restore` | (removed) | Directory-level restore is trivial |
| `hats stash` | (removed) | Not needed with isolated dirs |
| `hats unstash` | (removed) | Not needed with isolated dirs |
| (new) | `hats link <account> <resource>` | Share resource with base |
| (new) | `hats unlink <account> <resource>` | Isolate resource from base |
| (new) | `hats status [account]` | Show resource sharing status |
