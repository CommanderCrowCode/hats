# CONSTITUTION

Living document of engineering principles learned the hard way. Each rule here came from a specific incident — when you're tempted to violate one, read the "why" before deciding you know better.

---

## I. Data copied across boundaries will drift

**Rule**: Any time the same data exists in two places, assume it WILL drift. Either eliminate the duplication or add a sync test.

**Why**: relay-mesh 2026-04-09 session — adapter source files (`adapters/claude-code/hooks/*.sh`) had `TMUX_PANE` injection, `system:` prefix filtering, and silent-exit logic. The equivalent embedded Go constants in `cmd/server/main.go` did NOT. Every `relay-mesh install-*` wrote the STALE embedded version to disk. Agents registered without tmux panes for days. Similar bug: codex `SKILL.md` was missing YAML frontmatter because the embedded `codexSkillContent` constant was never updated when the format requirement was added.

**Common drift sources**:
- Code constants generated from or mirroring external files
- Protocol text in server vs what agents actually do
- Generated bindings (protobuf, graphql, ORM models) vs schema
- Cache / snapshot files vs live source
- Dashboard state derived from SSE events vs authoritative backend state
- Installed binaries vs source code

**How to apply**: Whenever you write `const foo = \`some content\`` in code that also exists in a file, add a sync check. The `embedded-source-sync` skill has ready-to-run patterns.

---

## II. Write success ≠ delivery success

**Rule**: Don't declare success until the layer the user cares about confirms. A successful write to a queue, file, or buffer is not the same as the recipient acting on the data.

**Why**: relay-mesh watcher used push adapter (write to `pending-messages.json`) as its primary nudge mechanism. Push always "succeeded" because writing to a file never errors. But idle agents never read the file — the stop hook only fires on tool calls. Result: the watcher generated ~2,500 useless push nudges over 40 hours to dead agents. The tmux `send-keys` fallback (which IS a real signal — it types into a live terminal) was never reached because push "succeeded" first.

**Fix pattern**: When you have multiple delivery channels, rank them by **observability**, not by order of implementation. Channels where success is externally verifiable (a human sees output, a process wakes up, a response arrives) come first. File writes and queue pushes come last.

**Common offenders**:
- Fire-and-forget queues that report success on enqueue
- DB writes before flush
- Webhook "delivered" that just means "accepted by our outbox"
- Notification services returning 200 for "accepted"

**How to apply**: When reviewing delivery code, ask "what would have to go wrong for this success to be a lie?" If the answer is "the user doesn't see it," rank the channel lower.

---

## III. Liveness ≠ recency

**Rule**: Elapsed time is a poor proxy for "is this alive?" Use direct liveness signals when available.

**Why**: relay-mesh almost shipped a time-based auto-deregister (60-min deaf → remove agent). During the 36-hour monitoring session, multiple agents went dormant for 3+ hours and came back. One woke up after 16 hours and resumed work. A timer-based kill would have murdered live agents. The right signal was **does the tmux pane still exist?** — an active, verifiable liveness check, not "how long since we heard from them."

**Fix pattern**: Before picking a timeout, ask if there's a direct signal. For processes: does the PID exist? For tmux panes: `tmux has-session -t <pane>`. For network peers: can we ping? For HTTP clients: did the connection close? Fall back to timers only when no direct signal is available.

**How to apply**: Any place you're about to write `if time.Since(lastSeen) > threshold { markDead() }`, pause. Look for a direct liveness signal first.

---

## IV. Silent failures compound until something explodes

**Rule**: For any file format or data boundary where parsing errors are silent, add active validation. Never trust "it parsed" — verify the rules actually applied.

**Why**:
- One stray `}` in embedded CSS killed 60 rules. The browser didn't error — it just stopped parsing. Debugged only after Playwright showed `backgroundColor: rgba(0, 0, 0, 0)` where we expected red.
- Codex silently rejected `SKILL.md` because of missing YAML frontmatter. No warning in the logs — the skill just didn't load.
- Pre-commit hooks looked correct in source but had uninjected `$TMUX_PANE` because the embedded constant was old. Every installation for weeks was silently broken.

**Common silent-failure formats**:
- CSS (unbalanced braces → cascade failure, no error)
- YAML (missing `---`, wrong indent → silent fallback)
- Bash embedded in strings (unbalanced quotes, heredoc errors)
- JSON with trailing commas in lax parsers
- Go `const` string literals with backtick nesting issues
- JavaScript in `<script>` tags (throws, but UI silently fails)

**Fix pattern**: For each silent format, add a round-trip verification:
- CSS → query computed styles, verify non-default values
- YAML → extract frontmatter, validate required fields
- Bash → `bash -n` syntax check
- JS → `node --check`
- Embedded strings → extract and validate the extracted content

The `embedded-source-sync` skill contains ready-to-run verification patterns.

---

## V. Cleanup is a day-1 design problem

**Rule**: Any long-running service that accumulates entries (sessions, connections, files, queue entries, map keys) must have a cleanup policy designed in on day 1, not bolted on later.

**Why**: relay-mesh accumulated forever:
- Dead agents stayed in the registry indefinitely (watcher detected them as deaf but never removed them)
- `pending-messages.json` grew with every broadcast because nobody pruned consumed entries
- SSE listeners leaked on browser reconnect — 7 simultaneous connections from one tab
- Dead agents queued messages from other agents that didn't know they were dead

The fix required a watcher overhaul (tmux-first nudging, dedup, escalation tiers, dormant status, auto-deregister) AND a storage refactor (per-agent files instead of shared) — all after the fact, under load, during an active session.

**Common accumulation points**:
- Session stores / registries / caches
- Log buffers
- Event history
- Connection pools
- Background task queues
- Filesystem scratch directories
- NATS/Kafka stream retention
- In-memory maps keyed by ID

**Fix pattern**: Every accumulating data structure needs documented answers to:
1. **Who adds entries?** Under what conditions?
2. **Who removes entries?** Under what conditions?
3. **What's the steady-state size?** Under normal load vs peak?
4. **What's the worst case?** If the remover stops, how big can it get?
5. **What's the observability?** Can you see the current size from outside the process?

If any of these is "I don't know" or "nobody," you have a leak.

---

## VI. Observability before optimization

**Rule**: You can't fix what you can't see. Before optimizing, make the problem visible. Before declaring victory, verify the fix with external observation, not source code inspection.

**Why**: The relay-mesh sweep found 23 issues. At least 15 of them were invisible until someone watched the logs for hours. The "watcher wastes cycles on dead agents" bug had been running for weeks — nobody noticed because there was no metric for "nudge-to-fetch conversion rate." Multiple CSS fixes looked correct in source but weren't applied in the browser. The difference between "I wrote the code" and "it works" was only discoverable via Playwright querying computed styles.

**Fix pattern**: Before any non-trivial change to a complex system:
1. Can you see the current behavior via logs, metrics, or a live query?
2. After your change, can you see the new behavior the same way?
3. If the answer to either is "no," add observability FIRST, then make the change.

For UI changes specifically: **the browser's computed style is authoritative, source code is not.** Use Playwright or browser DevTools.

For backend changes: add a log line or metric before the change so you have a baseline to compare against.

---

## VII. Don't trust your own tests if they share state with production

**Rule**: If your tests touch the same directories, files, or config as a running production instance, they're lying to you. Isolate test state or don't run them against a live system.

**Why**: During relay-mesh work, we repeatedly installed new binaries while a live session was running, causing cascading disruption. We had to add "BUILD ONLY, NO INSTALL" as an explicit constraint for the team fix sprint because every teammate otherwise reflexively ran `make install`. The `~/.claude/hooks/` directory was shared between the test environment and live agents — edits to test fixtures affected real sessions.

**Fix pattern**: Test fixtures live in temp directories. Production state lives in the user's home. Never the twain shall meet. If your tooling makes this hard (embedded Go binaries that install globally), your tooling is the bug.

---

---

## VIII. "It works on my machine" means it doesn't work

**Rule**: If the only place your change has been verified is in your editor, your change is unverified. Verify in the target environment.

**Why**: Multiple times during relay-mesh work, CSS edits looked correct in the source file but rendered wrong in the browser. Hook changes looked correct in the adapter `.sh` but the installed copy was stale. Embedded Go constants looked correct in `main.go` but weren't rebuilt into the running binary. Each time, we "knew" the fix was right and had to walk it back.

**Fix pattern**:
- For UI: Playwright or browser DevTools verify computed styles.
- For installed files: `diff` the installed copy against the source.
- For running binaries: check version/build timestamp, not just `make build` output.
- For deployed services: `curl` the endpoint or check a metric, not just "the deploy script exited 0."

**How to apply**: Before saying "done," ask: "Where would I look to see this change ACTIVE?" If the answer is "the source file," you haven't verified.

---

## IX. Rollout order matters more than code quality

**Rule**: A correct change shipped wrong breaks things. Plan the rollout sequence before you start editing.

**Why**: During the team fix sprint, we nearly had teammates editing the same files (`handler.go`, `watcher.go`, embedded stop hook) simultaneously. The explicit constraint "BUILD ONLY, NO INSTALL" had to be repeated because teammates reflexively ran `make install`. push-fixer's task depended on broker changes; hook-syncer's task depended on push-fixer's rewrite. Without a dependency graph in the task definitions, teammates would have blocked each other or overwritten each other's work.

Before that, every time we restarted relay-mesh to install a new binary during an active session, we disrupted live agents.

**Fix pattern**:
- **For multi-person work**: map file ownership. Who's touching what? Who depends on whom? Sequence or claim.
- **For schema/config changes**: old and new must coexist during the migration window. Never flip both sides atomically.
- **For live system changes**: is there an active session? If yes, the change cannot require a restart mid-session.
- **For embedded resources**: change the code that generates them BEFORE the systems that consume them, not after.

**How to apply**: Before the first edit, answer "what's the order?" If you can't, don't start.

---

## X. The exception is the interface

**Rule**: How a system fails is part of its API. Error messages, retry behavior, fallback chains, and degraded states are contracts you must design, not accidents you allow to emerge.

**Why**:
- Ack suppression: the heuristic `body starts with "done"` caused `"Done. typhoon-asr memory_budget_gb updated to 34.0..."` to be silently dropped. The "how it fails" (silent drop) was the interface, and we hadn't designed it.
- Send response body leak: agents saw their own messages echoed back in send responses, then wasted cycles processing "outbound echo." The interface wasn't the success path — it was the fact that success returned too much information.
- Watcher nudge failure: when push "succeeded" but the agent didn't wake, the watcher didn't know. Its internal model of "nudged = awake" was wrong because the failure mode was invisible.

**Fix pattern**:
- Design the error path alongside the happy path. What does the caller see on partial failure? Timeout? Backpressure?
- Explicit > implicit. `type="ack"` is better than a content heuristic because the sender's intent is unambiguous.
- Failure modes should be observable. If the watcher's push nudge was "likely to have succeeded," not "definitely delivered," make that distinction visible to the watcher itself.
- Return the minimum information needed. Don't return the request body in the response.

**How to apply**: For every public method or endpoint, write down: happy path, expected failure modes, unexpected failure modes, and what the caller sees in each. If you can't articulate the failure contract, you haven't finished designing the interface.

---

## XI. Fix the rule, not the instance

**Rule**: When you find yourself fixing the same class of bug twice, stop fixing instances and fix the mechanism. Automate the detection so it can't come back.

**Why**: We fixed the same CSS brace bug twice before codifying it in the `embedded-css-guard` skill. We fixed the same "embedded Go constant drift from adapter source" bug twice (TMUX_PANE injection, then system: prefix) before adding drift detection to the QA script. Each instance fix cost ~30 minutes; the skill/automation cost one ~30-minute investment and prevents all future instances.

**Fix pattern**:
- After fixing a bug, ask: "Is this class of bug I've seen before? Can I detect it automatically? Can I make it syntactically impossible?"
- First instance: fix it.
- Second instance: fix it AND add a test/check/skill that would have caught both.
- Third instance: you waited too long. Stop all current work and fix the mechanism NOW.

**How to apply**: When closing an issue, ask "what check would have caught this?" If there's a cheap check, add it.

---

## XII. Shared state is the wrong default

**Rule**: When multiple actors need to read/write the same data, the default should be per-actor (isolated) state. Only share when there's a specific reason to coordinate.

**Why**:
- `pending-messages.json` was shared across all Claude Code sessions. Every session read all entries, filtered to its own, wrote the rest back. This made single-session work O(n) where n = total pending messages across all sessions. With 8 agents, it became unusably slow.
- Dashboard SSE listeners accumulated because browser reconnects created new listeners without cleaning up old ones. Shared global listener registry with no per-client tracking.
- The running relay-mesh server holds `deregistered map[string]time.Time` — single map for all agents. If that grew unbounded under load, it would leak.

**Fix pattern**: When adding a new stateful component, ask "who owns this?" If the answer is "everyone" or "the system," you're defaulting to shared state. Is that necessary? Can it be per-agent, per-session, per-request?

The `pending-messages.json → pending/{agent_id}.json` refactor eliminated 60-80% of watcher noise overnight. It was a 30-line change that would have been trivial to do correctly on day 1.

**How to apply**: Shared state needs justification. Per-actor state is free.

---

## XIII. Your debugger is the browser/OS/system, not your head

**Rule**: When you're stuck, stop guessing. Use the actual inspection tools — not your mental model of what the code does.

**Why**: The nudge-all button "was too small" for four iterations because I kept tweaking CSS in the source file and asking the user what it looked like. It turned out a stray `}` was causing the parser to silently drop rules — something only visible via `document.styleSheets[0].cssRules.length` in the browser console. Three failed attempts could have been avoided with one Playwright query.

Similarly, the "agents deaf 8 hours" observation required actually tailing the log for hours — sitting and reading. Not looking at the code and reasoning about it.

**Fix pattern**:
- For DOM/CSS issues: `getComputedStyle()`, `document.styleSheets`, Playwright.
- For process state: `ps`, `lsof`, `/proc/$PID/`.
- For network state: `curl`, `ss`, tcpdump, Wireshark.
- For database state: actually query it. Don't reason from migrations.
- For agent/AI behavior: read the actual logs, don't model the agent.

**How to apply**: When your third attempt at a fix doesn't work, your mental model is wrong. Stop coding. Use a real inspection tool and confirm what the system is actually doing.

---

## XIV. Heuristics need guardrails

**Rule**: When you must use a heuristic (content-based classification, pattern matching, fuzzy rules), you need guardrails that catch the most dangerous wrong decisions — especially ones that silently discard information.

**Why**: Ack suppression used a content heuristic: "body starts with 'done'". A message saying "Done. typhoon-asr memory_budget_gb updated to 34.0..." was silently dropped. The user never received critical infrastructure info.

We eventually added TWO guardrails:
1. **Explicit declaration**: `type="ack"` parameter — lets the sender bypass the heuristic.
2. **Content guardrail**: if `type="ack"` but body >80 chars or contains URLs/paths/code blocks, override and deliver anyway with a warning.

The combination is strong: explicit wins by default, but you can't accidentally suppress real content.

**Fix pattern**: For any heuristic that makes a silent decision:
- Add an explicit opt-out or opt-in for the caller.
- Add a "common-sense" guardrail that catches the most dangerous wrong decisions (e.g., "if the message is this long, it's probably not an ack").
- Log when the heuristic fires, especially when a guardrail overrides it.

**How to apply**: If your heuristic can silently discard information or take a destructive action, it needs at minimum: an explicit bypass, a guardrail, and a log line.

---

## XV. The user is part of the system

**Rule**: Design for the human in the loop. Confusing labels, invisible state, and jargon leaking to the UI are all bugs.

**Why**:
- The tmux pane preview showed `%32` as the title. The user said "users might think that's work or progress percentage, which is not the case." This was a 5-character fix that had shipped twice.
- The stop hook initially said "You have 7 new messages from: system:watcher, system:dashboard" — exposing server internals in user-facing output. Confusing and useless.
- The nudge-all button was "too small to see" across four redesign attempts because the designer (me) didn't verify visually.
- Dashboard unread counts drifted from reality because the SSE tracker didn't resync on reconnect. The user refreshed and saw different numbers.

**Fix pattern**:
- Internal identifiers (pane IDs, agent UUIDs, session tokens, system senders) should not appear in user-facing strings unless they're actionable.
- Labels should describe what the user sees, not what the code named the thing.
- State shown to the user should be re-verified against authoritative sources on refresh, not trusted from cached streams.
- Every UI change must be verified IN the UI, not in the source.

**How to apply**: Read every string that reaches a human. Ask: "would a user without the codebase in their head understand this?" If no, fix it.

---

## XVI. Undo > confidence

**Rule**: Prefer designs that allow undo over designs that require you to be right the first time. Make destructive actions reversible, confirmable, or delayed.

**Why**: The instinct to build "auto-deregister dead agents after 60 minutes" would have killed agents dormant for 8+ hours. An undoable version — mark "dormant," stop nudging, but keep the registration — was strictly better. If a dormant agent woke up, it just needed to start fetching again. No recovery step.

Similarly, the nudge mechanism uses push adapters (soft — write to file, agent reads when ready) alongside tmux send-keys (harder — types immediately into the terminal). The soft channel is recoverable; the hard channel is not. Both existing gives the system resilience.

The `deregistered map[string]time.Time` TTL (10 min) is another undo window — if we're wrong about an agent being dead, it stays in the "recently deregistered" map and the caller gets a clear error ("recipient agent not found (deregistered)") rather than a generic 404.

**Fix pattern**:
- Destructive actions should have a grace period, confirmation, or soft-delete.
- Auto-remediation should prefer "mark for review" over "delete."
- State transitions should be reversible when possible. "Dormant" is better than "deleted."
- When deletion is final, leave a tombstone so downstream callers get a clear error.

**How to apply**: For any operation that can't be undone with equal cost, ask: "what if I'm wrong?" If the answer is "the data is gone," design for a grace period or soft-delete instead.

---

## XVII. Monitor the monitor

**Rule**: The observability system itself can fail. Build a cheap check that verifies monitoring is working — before you rely on it in an incident.

**Why**: During the 40-hour monitoring session, we had one point where SSE clients were disconnecting and reconnecting en masse. The log showed the disconnects. But we almost missed it because:
1. No alert existed for "listener count jumped to 7."
2. The SSE event counter (#66) didn't exist yet to detect gaps.
3. The dashboard itself was the monitoring, and it was the thing failing.

If we hadn't been actively reading logs, the leak would have gone undetected until the server ran out of file descriptors.

**Fix pattern**:
- Add a metric for the metric pipeline itself (e.g., "events published this minute").
- Alert on absence as well as presence. "No events for 5 minutes" is often a bigger signal than "high event rate."
- Verify monitoring works BEFORE you need it. A dashboard that only gets tested during incidents is untested.
- Don't rely on the primary observability channel to monitor itself.

**How to apply**: Your monitoring should have a heartbeat that's visible from outside your monitoring system. If your metrics pipeline dies, you should find out some other way.

---

## Addendum: How to use this document

- **When to read**: Before starting any significant refactor, new feature, or architectural change. Before pushing a fix you're "pretty sure" about. Any time you feel the urge to take a shortcut.
- **When to add**: After any incident that felt avoidable in hindsight. After any bug that matched a pattern we've seen before. After any review where the reviewer said "I've seen this before."
- **When to edit**: When a rule proves too broad, too narrow, or wrong. Bias toward keeping history — add a "Revised:" note rather than deleting.
- **Format**: Numbered principle → Rule → Why (concrete incident) → Fix pattern → How to apply. Generic advice without a specific incident behind it doesn't belong here.
- **Incident attribution**: When adding a new principle, cite the date and system where you learned it. "relay-mesh 2026-04-09" is enough. Future you will thank present you for the context.
