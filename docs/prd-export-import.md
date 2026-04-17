# PRD — `hats export` / `hats import`

**Status:** draft, not yet implemented
**Roadmap slot:** v1.1 (see `ROADMAP.md`)
**Author:** hats-lead (2026-04-17)

## Problem

Operators who manage hats accounts across multiple machines currently have
no first-class way to move an account. The workflow is:

1. Tar up `~/.hats/claude/<account>/` on machine A
2. Scp to machine B
3. Untar into `~/.hats/claude/` on machine B
4. Hope symlinks still resolve (they don't — relative `../base/...` targets
   are broken until `hats fix` runs)
5. Run `hats fix` to re-link everything
6. Realize the credential file was bundled with the wrong permissions, or
   the `.claude.json` contains stale onboarding state, or the new machine's
   `base/` doesn't have the resources the old one's symlinks expect

This is manageable but error-prone. A single `hats export <name>` and
`hats import <file>` pair would make the happy-path a two-command
operation.

## Goals

1. **Portability.** Export archive runs on any target machine with hats
   installed, regardless of source OS / hats version (within a major
   version range).
2. **Safety.** Credentials are encrypted at rest in the archive; decryption
   requires a password or key that the operator controls.
3. **Reproducibility.** `hats import` produces an account directory
   bit-identical (modulo per-machine state) to the source.
4. **No network.** Both commands are pure filesystem operations — no
   third-party storage. Operator handles transport.

## Non-goals

- Syncing (continuous replication across machines) — out of scope; if a
  team wants that, point them at git-crypt + shared repo.
- Bundling `base/` — only per-account state travels. The target machine
  should already have `hats init` done.
- Preserving running-session state (sessions/, caches) — those are
  per-machine.

## UX

```bash
# Source machine
hats export work > work.hats             # stdout, piped to encryption
hats export work --out work.hats.enc     # explicit output + encryption
hats export work --no-encrypt > work.tar # opt out (not recommended)

# Target machine
hats import work.hats.enc                # prompts for password
hats import work.hats                    # unencrypted (takes any tarball)
hats import work.hats --as personal      # rename during import
```

**Environment variable:** `HATS_EXPORT_PASSWORD` (or passphrase file via
`--password-file <path>`) for non-interactive use.

## Archive format

**Candidate A — encrypted tarball (age or gpg):**

```
work.hats.enc  (age/gpg-encrypted)
  └── (decrypted: tarball)
       ├── MANIFEST.json
       │     { "name": "work", "provider": "claude",
       │       "hats_version": "1.2.0", "exported_at": "2026-04-17T08:10Z",
       │       "isolated_files": [".credentials.json", ".claude.json"] }
       ├── .credentials.json   (mode 600)
       ├── .claude.json
       └── sessions/            (optional; default: excluded)
```

**Why age:** single-binary, modern crypto, minimal deps. Licensed BSD. One
flag (`-p`) for password-based, `-r recipient` for public-key-based.

**Fallback:** gpg (more widely installed, more flags required, legacy).

**Implementation suggestion:** detect which of `age`, `gpg`, or
`openssl enc` is available at runtime; pick in that order; document.

## Implementation sketch

### `hats export <name>`

1. Resolve `$acct_dir = _account_dir "$name"`; die if missing.
2. Build manifest with `name`, `provider`, `hats_version`, `exported_at`,
   `isolated_files` (the set actually present in `$acct_dir` that match
   `ISOLATED_PATTERNS`).
3. `tar -cf -` the isolated files + manifest from `$acct_dir`.
4. Pipe through `age -p` (or equivalent) unless `--no-encrypt`.
5. Write to stdout or `--out` path.

### `hats import <file>`

1. Detect encryption header; prompt for password if encrypted.
2. Decrypt → tar → temp dir.
3. Parse MANIFEST.json; validate `hats_version` is compatible (same major).
4. Determine target account name (MANIFEST.name, or `--as` override).
5. Call `_validate_name` on the target name.
6. If target account already exists: require `--force` or bail.
7. Create target account dir; copy files from temp with mode 600 preserved
   for credentials.
8. Call `_setup_account_dir` (existing helper) to populate shared symlinks
   from base.
9. Call `hats fix` under the hood to reconcile.
10. Clean up temp dir.

## Security considerations

- **Exported credentials are valuable.** Default to encrypted output;
  `--no-encrypt` prints a prominent warning.
- **Password strength is operator's responsibility.** Don't try to enforce
  in the CLI — document best-practice in README / SECURITY.md.
- **Manifest pollution.** Don't blindly import whatever's in MANIFEST; the
  implementation only extracts files that match `ISOLATED_PATTERNS` for the
  declared provider. Arbitrary file names in the archive must be rejected.
- **Symlink safety.** If the archive contains symlinks (it shouldn't),
  `tar --no-same-permissions --no-same-owner --no-symlinks` or equivalent.
- **Path-traversal in archive.** `tar` extraction of
  `../../etc/passwd` → reject with `tar -P` / `--keep-directory-symlink`
  off / extract into a temp dir first and only copy named files to target.

## Testing

- Smoke: export a fixture account on a sandboxed HATS_DIR, import into a
  fresh sandbox, verify byte-equal credential + .claude.json.
- Encryption round-trip with a password.
- `--as` rename.
- Malicious archive rejection (crafted tar with `..` paths).
- `hats_version` compatibility check.

## Open questions

1. Age vs gpg vs openssl — pick one default. Preference: age for its
   simplicity. Optional fallbacks should degrade gracefully with a warning.
2. Do we ever export `base/` snapshots (team-sharing scenario)? Out of
   scope for v1.1; revisit for v2.0.
3. Should `hats import` overwrite an existing account by default or
   require `--force`? Recommendation: require `--force` (matches `rename`
   semantics).
4. Should the manifest carry Codex `config.toml` overrides that the
   account had unlinked from base? Yes — include a `locally_overridden`
   list so `hats import` can recreate them.

## Estimated effort

- Design + PRD (this doc): 30 min.
- Implementation (hats export + hats import + tests + docs): 4-6 hours of
  focused work, assuming `age` is the chosen crypto dep.
- CI coverage for encrypted roundtrip: +1 hour.

## Sequencing

1. Ship a gh issue with this PRD attached; gather operator feedback.
2. Pick age vs gpg based on Tanwa's preference.
3. Implement in a feature branch; ship behind a `HATS_EXPERIMENTAL=1` env
   gate for first couple of releases.
4. Remove the experimental gate in the next minor after verified in-the-wild.

## Acceptance criteria

- [ ] `hats export <name> > file.hats` produces a valid encrypted archive
- [ ] `hats import file.hats` reconstructs the account with correct mode 600
      on credentials + all shared symlinks in place
- [ ] Malicious archive (path-traversal entries) is rejected with a clear
      error
- [ ] Version-incompatible archive is rejected with a clear error
- [ ] Smoke-test coverage for export/import roundtrip passes on
      ubuntu-latest + macos-latest
- [ ] Documentation: README + SECURITY.md mention the threat model
