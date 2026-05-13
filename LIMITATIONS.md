# Known limitations (v0.1.0)

What works is in [README.md](./README.md). This file is what *doesn't* work, ranked by how much it matters.

Hand-verified against the implementation at commit `59f1307` (phase 7) on 2026-05-13. The first two items in the initial cut — meta.yaml race and CANCEL not killing claude — are fixed in the follow-up commit; the rest remain.

## Implementation gaps from the spec

### No worktree-per-task for `kind: code`

[`spec/06-claude-code-backend.md`](./spec/06-claude-code-backend.md) describes spawning code-kind tasks inside a `git worktree` so the user's main checkout is untouched. Not implemented. `runClaude` uses `fmRepo` (or the task dir) directly as the working directory; if you run a `kind: code` task against your live repo, claude edits files in place.

**Workaround:** set `repo:` in the task frontmatter to a dedicated checkout you don't mind being edited, or commit/stash before running.

### No auto-PR on done

Spec mentions a "land pipeline that watches CI + opens PR" as a borrowed Symphony idea. Not implemented. After a code task completes, the user runs `git diff`/`git commit`/`git push` themselves.

### `pot do gc` not implemented

Spec defines `pot do gc [--older-than DURATION]` to clean up old `transcript.jsonl` files. Verb is documented but the command isn't wired up. Disk hygiene is on the user.

### `pot do list --since DURATION` not implemented

The flag is documented; the filter isn't wired up. Other filters (`--status`, `--kind`) work.

### `--raw-transcripts` is implicitly always on

Spec says `transcript.jsonl` is opt-in behind `pot do watch --raw-transcripts`. Implementation always writes the jsonl. Costs disk; doesn't break anything.

### No `--max-cost-usd-per-day` enforcement

Spec defines a daily aggregate cap on `pot do watch`; not implemented. Per-task `budget_usd` → `claude --max-budget-usd` still works.

## Architectural caveats

### Single-process `pot do watch` per vault

Documented in the spec. Two watchers on the same vault would race on claim and over-spawn. If you need more parallelism, raise `--max-concurrent` on one watcher rather than running two.

### We dropped `--bare` from the claude spawn

Spec calls for `--bare` to skip auto-discovery (hooks, MCP, CLAUDE.md, plugins, skills) so spawns are reproducible. In practice `--bare` *also* skips credential discovery — claude responds "Not logged in" even with valid subscription auth. We drop the flag and rely on `--allowedTools` to constrain the tool surface. Side effects:

- The user's `CLAUDE.md` files leak into spawns.
- The user's project hooks fire.
- The user's MCP servers connect.
- The user's plugins and skills load.

For a single-user setup this is acceptable. If reproducibility becomes a problem, a follow-up: detect which `--bare`-equivalent claude flags exist (`--no-hooks`? `--no-mcp`?) and use them piecewise.

## Build / provisioning

### `cabal2nix` is broken on current `nixpkgs-unstable`

Transitively through `subversion` → `apr-util` → `dbm/sdbm/sdbm_pair.c` which uses K&R-style function definitions that modern clang rejects (`-Werror=implicit-int`). Until upstream patches it, regenerating `nix/pot.nix` requires either:

1. Hand-editing (what we do — see header comment in `nix/pot.nix`).
2. Running `cabal2nix` on Linux where the build succeeds.
3. Waiting for an upstream fix.

Whenever you add/remove a Haskell dep, edit both `potentiality.cabal` *and* `nix/pot.nix` in the same commit.

### NixOS module is intentionally thin

`flake.nix` exports `nixosModules.{default,potentiality}` (a systemd-user-service that runs `pot do watch`). The module only exposes the flags the binary actually implements: `--vault`, `--max-concurrent`, plus an `extraArgs` escape hatch. Spec'd-but-unimplemented knobs (`--log-level`, `--max-cost-usd-per-task`, `--max-cost-usd-per-day`, `--raw-transcripts`, `--dry-run`) are absent from the module on purpose — they don't exist in `CLI.hs` yet, so wiring them in would just break the service. When they land, both the module and the gap entries above need an update in the same commit.

## Quality

### No tests

The library is end-to-end-verified by running the binary, not by Haskell unit tests. The frontmatter parser, ULID generator, and `pot agent ask` blocker would all benefit from `hspec` / `hedgehog` tests. Add as features mature; not a v1 priority.

### Token-cost telemetry is best-effort

Cost numbers in `meta.yaml#total_cost_usd` come from claude's `result` event. Claude doesn't always emit one (some failure paths exit before result). When that happens, cost is missing from meta — but it's still tracked claude-side. v1.1 idea: persist a per-day running total in `vault/_potentiality/cost.yaml`.

## Out of scope (by design — not limitations)

See [`spec/10-non-goals.md`](./spec/10-non-goals.md) for things we deliberately did not build: HTTP server, MCP server, database, multi-tenancy, distributed workers, web UI, GitHub-Issues-as-tracker. Those won't move into this list — they're not coming.
