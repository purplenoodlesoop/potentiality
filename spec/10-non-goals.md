# 10 — Non-goals

Things deliberately not built, and why. If a future change adds one of these, the rationale here should be revisited explicitly.

## No HTTP/REST/gRPC server

There are no listening sockets. `pot do watch` is a long-running process, but it talks to nothing over the network on the inbound side.

**Why:** Adds a TLS story, an auth story, a port-binding story, a firewall story, and a service-discovery story — all for benefits that the vault already provides (visibility, mobile access, multi-process composition).

## No MCP server, no MCP consumption we introduce

Potentiality does not implement an MCP server, and does not require Claude Code to consume any MCP server that Potentiality provides. Claude Code may continue to consume user-configured MCP servers via the user's own settings, but `pot` runs claude with `--bare` by default, which skips auto-loading them, for reproducibility.

**Why:** matches Horizon's stated design philosophy and keeps the surface area to "bash subcommands + files." Adding MCP would duplicate the IPC story without changing what's possible.

## No database

No SQLite, no Postgres, no embedded KV store, no Redis. The vault is the database.

**Why:** Symphony's design needs Postgres because it serves a team with concurrent writers and complex queries. We have neither. Files + grep + git are sufficient and ship-with-zero-deps.

## No multi-tenancy / multi-user / authentication

Potentiality assumes one user, one vault, one set of API credentials. There is no concept of user accounts, RBAC, tenant isolation, or per-user budgets beyond what a single API key provides.

**Why:** P5 from [01-philosophy.md](./01-philosophy.md). Multi-user is a different product. If a second user shows up, the right move is probably "run another instance with another vault," not "add an auth layer."

## No distributed workers / SSH execution

Symphony has a `worker_host` model where tasks can run on different machines over SSH. Potentiality runs everything on one machine.

**Why:** the failure modes of remote execution (SSH key management, file sync between hosts, partition handling) cost a lot for a benefit ("more concurrency") that one user does not need. If a user does need more concurrency, vertical scaling (a beefier box) is sufficient up to dozens of parallel agents.

## No web UI / dashboard

No Servant, no LiveView, no built-in HTML viewer. Inspection is via `pot do list`, `pot do show`, `pot do tail`, or by reading the vault with Obsidian / Working Copy / `cat`.

**Why:** the vault is already a UI for desktop (any editor). The chat client (Horizon, OpenClaw, …) is already a UI for mobile. A web dashboard would be a third UI for the same data. If `pot do show` output ever feels limiting, ship a `pot do show --format html` flag — still no server.

## No tracker integrations (Linear, GitHub Issues, Jira) in v1

Symphony's reference implementation is Linear-first. Potentiality is vault-first.

**Why:** the tracker IS the vault. Adding a "sync to GitHub Issues" feature is plausible v2 if there's a reason (public visibility, team handoff), but it would be a one-way mirror outbound, never the source of truth inbound. The vault remains canonical.

## No agent-backend pluggability surfaced to users in v1

The `AgentBackend` typeclass exists in the code (so Codex/Aider/Gemini adapters can be added later), but `claude -p` is the only implementation. The kind/mode/permission_mode/allowed_tools fields are not abstracted; they're Claude Code's vocabulary.

**Why:** chasing pluggability before there's a second user (i.e., second backend) leads to over-engineered abstractions. Add Codex when someone actually wants Codex.

## No real-time progress UI for the user

Token-level streaming reaches `transcript.md` as it happens, but the chat client only ships one notification per question/plan/status-change, not continuous streaming (which would be obnoxious).

**Why:** "look at the transcript when you care" is a better UX than "ping ping ping." A `pot do tail --follow` on the server gives full real-time view for when you do care.

## No automatic git push

`pot` commits to the vault. It does not push. Nor does it commit in the user's working repos for `kind: code` tasks (it leaves changes staged or in a worktree).

**Why:** push semantics belong to the user. A daemon that pushes to a remote without prompting is one ransomware-API-key away from a bad day. The user runs `git push` on a cadence they choose.

## No fan-out / coordination between tasks

Tasks are independent. `depends_on:` exists in the schema for sequencing (do this after that), but there's no parent-child, no shared memory, no aggregation, no "wait for all of these and synthesize."

**Why:** Claude Code already has the `Task` subagent tool for in-task fan-out, which is the right granularity for an LLM. Cross-task coordination, if needed, can be handled by the user creating a follow-up task that depends on the prior set.

## No prompt versioning / prompt management

The system-prompt addenda are baked into the binary per kind. There is no `/prompts/` directory, no template engine for prompts, no "edit your prompt without recompiling."

**Why:** Symphony has WORKFLOW.md with Liquid templates because teams need to share/version workflows. One user can edit `src/Potentiality/Kind/Research.hs`, `cabal build`, restart. Faster than a template system would be.

## No multi-vault

`pot do watch` watches one vault. To watch two, run two daemons.

**Why:** simpler. Cross-vault dependencies are out of scope; the user can put everything in one vault.

## No SPEC.md conformance

We are not aiming to be a drop-in Symphony implementation. We borrow ideas; we do not promise wire/file/event compatibility.

**Why:** chasing conformance ties our hands. The Symphony tooling ecosystem (caclawphony, dashboards) is Elixir-centric and won't talk to us anyway. Our integration target is Horizon, not Symphony.
