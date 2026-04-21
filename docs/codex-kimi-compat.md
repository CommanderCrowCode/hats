# codex-kimi Compatibility Status

**Status:** DISABLED by default (`hats codex kimi doctor` FAILs)
**Decided:** 2026-04-21 (praetor P1 directive msg-e4343e5a3515e1da via hats-lead)
**Reason:** `wire_api` mismatch between codex CLI and Kimi endpoint — no first-party route.
**Re-enables:** either Kimi ships `/v1/responses`, codex re-allows `wire_api = "chat"`, or the operator stands up a LiteLLM proxy in front of Kimi (see workaround below).

## What works today (the alternative)

**`hats kimi`** (Anthropic-compat, claude-kimi) ships working end-to-end. Live `hats kimi doctor` is 5/5 green; interactive `kimi "..."` returns cleanly. Commits: [bc136e0](../commit/bc136e0), [8746d5a](../commit/8746d5a), [bbe1d7c](../commit/bbe1d7c). If you want Kimi access from the Tanwa mesh today, use claude-kimi — there is no current codex-kimi path that bypasses this document.

## Vendor-state receipts

### codex v0.118.0 (OpenAI) rejects `wire_api = "chat"`

Verified 2026-04-21 via `strings` of `/home/tanwa/.npm-global/lib/node_modules/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/codex/codex`:

```
`wire_api = "chat"` is no longer supported.
How to fix: set `wire_api = "responses"` in your provider config.
More info: https://github.com/openai/codex/discussions/7782
```

Only accepted enum value: `responses` (paths referenced in the binary: `/responses`, `responses_http`, `responses_websocket`). No `CODEX_CHAT_COMPLETIONS_COMPAT` / `CODEX_LEGACY_WIRE_API` / similar env override present in binary strings. codex is committed to Responses API end-to-end.

### Kimi / Moonshot serves `/chat/completions` only — no `/responses`

Fetched 2026-04-21:

- **Third-party-agents doc** — https://www.kimi.com/code/docs/en/more/third-party-agents.html
  - Claude Code recipe: Anthropic-compat on `api.kimi.com/coding/` (used by claude-kimi)
  - Roo Code recipe: OpenAI-compat on `api.kimi.com/coding/v1` (chat/completions only)
  - No Codex CLI recipe, no `/responses` reference.

- **Official platform API doc** — https://platform.kimi.ai/docs/api/chat (redirected from `platform.moonshot.ai/docs/api/chat`)
  - Only `/v1/chat/completions` published. No Responses API.

- **Curl probes** (2026-04-21 ~05:15Z):

| URL | HTTP | Meaning |
| --- | --- | --- |
| `api.kimi.com/coding/v1/responses` (GET) | 404 | Route does not exist |
| `api.kimi.com/coding/v1/responses` (POST) | 404 | Route does not exist |
| `api.kimi.com/coding/v1/chat/completions` (POST, no auth) | 400 | Route exists, body invalid |
| `api.moonshot.ai/v1/responses` (POST) | 404 | Route does not exist |
| `api.moonshot.ai/v1/chat/completions` (POST, no auth) | 401 | Route exists, auth missing |

**Conclusion:** `/responses` is not served at either Kimi-branded host. This isn't a "find the right URL" problem; the endpoint does not exist.

### Net

codex client requires `/responses`; Kimi server speaks `/chat/completions` only. No first-party path between them. The `hats codex kimi doctor` FAIL surfaces this state at the earliest place operators would see it, so they don't hit a confusing 404 at first `codex_kimi "..."` call.

## Workaround: LiteLLM proxy (operator opt-in)

LiteLLM Proxy exposes a `/v1/responses` endpoint and auto-bridges incoming `/responses` traffic to an upstream `/v1/chat/completions` for providers that don't natively support the Responses API. Reference: https://docs.litellm.ai/docs/response_api (quoted: *"Requests to /chat/completions may be bridged here automatically when the provider lacks support for that endpoint."*).

Architecture:

```
codex (/responses client)
   └─→ config.toml base_url = http://127.0.0.1:<port>/v1  (your local LiteLLM proxy)
         └─→ LiteLLM receives /v1/responses
               └─→ LiteLLM translates to /v1/chat/completions
                     └─→ POST https://api.kimi.com/coding/v1/chat/completions  (KIMI_API_KEY)
                           └─→ response bridged back → codex happy
```

Minimal LiteLLM config (`~/.litellm/kimi.yaml`):

```yaml
model_list:
  - model_name: kimi
    litellm_params:
      model: kimi/moonshot-v1-8k
      api_key: os.environ/KIMI_API_KEY
      api_base: https://api.kimi.com/coding/v1
```

Operator setup sketch:

1. `pipx install 'litellm[proxy]'` — installs the proxy as a standalone tool (avoids polluting hats' Python env).
2. `KIMI_API_KEY=$(hats kimi fetch-key | awk '{print $NF}') litellm --config ~/.litellm/kimi.yaml --port 4000` — or run as a systemd service.
3. `HATS_KIMI_CODEX_BYPASS_COMPAT_CHECK=1 hats codex kimi init` — provision the account dir; the env-gate silences the doctor FAIL.
4. Edit `~/.hats/codex/kimi/config.toml`:
   - `base_url = "http://127.0.0.1:4000/v1"`
   - `wire_api = "responses"`
5. `codex_kimi "hello"` should now round-trip end-to-end.

**hats deliberately does NOT bundle LiteLLM lifecycle management.** That's tracked as a separate P2 directive — see the Linear issue below. Until the P2 directive lands, the workaround is manual and operator-owned.

## Upstream-fix candidates (resolves without a shim)

Watch for either:

- **Kimi publishes `/v1/responses`** (Responses API native). Track: https://platform.kimi.ai/docs/api/chat + Kimi release notes.
- **codex re-adds `wire_api = "chat"` support** (unlikely given explicit deprecation). Track: https://github.com/openai/codex/discussions/7782.

When either ships, remove the doctor FAIL + this disabled status.

## Related

- Linear [MSH-647](https://linear.app/dancing-hippos/issue/MSH-647/codex-kimi-via-litellm-proxy-shim-p2-unblocks-codex-kimi-target-class): `codex-kimi via LiteLLM proxy shim (P2)` — operator-judgment call on bundling LiteLLM lifecycle into hats. Unblocks the `codex-kimi` target class in the B-19 flip helper (rotation framework).
- Commit: `feat(codex-kimi): ...` (this change) — adds the doctor FAIL + bypass env-gate + README note + this file.
- Prior commits in the codex-kimi series: [fbe77ed](../commit/fbe77ed) initial wrapper, [db577a0](../commit/db577a0) model-unpin.

## Changelog

- **2026-04-21** — Status set to DISABLED. Doctor FAIL + `HATS_KIMI_CODEX_BYPASS_COMPAT_CHECK=1` env escape hatch landed. Investigation receipts captured above. Investigator: hats-kimi-engineer (ag-1755a24ecbfb4a95).
