# Cycle Learnings — hats (/home/tanwa/hats)

## 2026-04-22 — hats-cycle-runner

### Finding: emitted shell-function env vars leak into parent shell

The `kimi` and `codex_kimi` shell functions emitted by `hats shell-init` inline-prefix
`ANTHROPIC_BASE_URL` / `ANTHROPIC_API_KEY` / `CLAUDE_CONFIG_DIR` (and codex-side
`OPENAI_API_KEY` / `CODEX_HOME`) on the runtime command invocation.

When the runtime command resolves to a shell function (as in smoke-test stubs
or any shell where `claude`/`codex` is a function), bash sets these variables
in the current shell. They persist after the function returns, leaking into the
parent shell and subsequent commands.

**Fix:** wrap the env-prefixed invocation in a subshell `( ... )`. The subshell
isolates the env mutation; the parent shell stays clean regardless of whether
the runtime is an external binary or a shell function.

Commit: 1a674ee
Verification: shellcheck clean, smoke 57/0 pass in clean env, fleet symmetry 5/0/0.

### Finding: dev shell env contamination masks test isolation

The operator's dev shell carries `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY`, and
`CLAUDE_CONFIG_DIR` from the active `kimi` shell-init. When smoke tests run in
this shell (without env isolation), the kimi env-isolation test sees these
pre-existing values and falsely reports a leak.

This is a test-environment issue, not a product bug. Running smoke in a clean
env (`env -u ANTHROPIC_BASE_URL -u ANTHROPIC_API_KEY -u CLAUDE_CONFIG_DIR`)
resolves it. The subshell fix above also makes the function robust, but the
test itself should ideally run in a fully isolated environment.

### Finding: shellcheck SC2015 in peer WIP

`tests/smoke.sh` line 642 uses `A && B || C` pattern which shellcheck flags as
SC2015 (info). This is in active peer WIP (hats-e2e-engineer C3 slice). The fix
is to rewrite as a proper `if` block:

```bash
if echo "$out" | grep -q "[kimi].*FAIL .credentials.json missing"; then
  kimi_fail=1
fi
```

Deferred to peer — shared-worktree serialization rule applies.

### Finding: peer WIP / smoke test mismatch on e2e probe scopes

`scripts/hats-e2e-probe` in working tree has expanded scope support (`kimi`,
`all`) beyond the HEAD smoke test expectations. This causes 1 FAIL in clean env:
`hats-e2e-probe accepted unimplemented scope (codex=2 kimi=1 all=1)`.

The peer (hats-e2e-engineer) has their WIP stashed at `stash@{1}`. Their
uncommitted working-tree changes extend the probe; the smoke test at HEAD still
expects `rc=2` for all non-claude scopes. This will resolve when the peer
commits their full slice.
