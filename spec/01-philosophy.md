# 01 — Philosophy

These are the rules that decide arguments. If a proposed feature breaks one of them, the feature is wrong.

## P1. Files are the database

Tasks, transcripts, findings, questions, answers, plans, status, and metadata all live as plain text under `vault/tasks/<ulid>/`. There is no SQLite, no Postgres, no embedded KV store, no in-process state worth losing on a crash.

**Why:** crash safety, audit logging (git), inspectability from any tool that reads files, mobile access (Obsidian, Working Copy, Telegram), and zero new infrastructure for the user.

## P2. The vault is the only inter-process contract

Horizon writes files. `pot` watches and writes files. Claude reads and writes files (through Read/Write/Edit and through `pot agent *`). No process ever calls another process over a wire.

**Why:** Horizon and Potentiality stay decoupled. Either can crash, restart, be replaced, or be reimplemented in a different language without the other noticing — as long as the file conventions hold.

## P3. No MCP. No JSON-RPC. No HTTP.

Potentiality offers no MCP server, consumes no MCP server it didn't already need, exposes no HTTP endpoints, and speaks no RPC. The agent-side surface is bash subcommands invoked through Claude's existing `Bash` tool. The orchestrator-side surface is the same binary's `pot do *` subcommands.

**Why:** matches Horizon's stated philosophy ("Tools are bash command templates with shell-escaped parameters — explicitly not MCP"). One design language across both projects. No transport, no schema duplication, no server lifecycles.

## P4. One static binary

`pot` is one GHC-compiled binary. It contains the orchestrator, the watcher, the agent-side blocking primitives, the YAML parser, the stream-json parser, and the optparse-applicative CLI. It is distributed via Nix flake using [`purplenoodlesoop/core-flake`](https://github.com/purplenoodlesoop/core-flake).

**Why:** mirrors Horizon's distribution (`nix run github:purplenoodlesoop/horizon`). Single deployment unit. No language runtime to install. No "did you run `npm install`."

## P5. Solo user is the only first-class user

Multi-user, multi-tenant, authentication, RBAC, audit gates, and "the team" are out of scope until and unless they are needed by an actual second user.

**Why:** Symphony spent most of its complexity budget on team primitives. We have a different target. Adding them later is easier than removing them; adding them speculatively is wasted effort that drags every later decision sideways.

## P6. CLI over daemon

`pot do run <task>` is the canonical execution path. `pot do watch <vault>` is an optional always-on convenience that wraps it. The binary should be useful from a one-off shell, not just from a systemd unit.

**Why:** matches how solo devs actually use coding agents (per HN/Composio surveys). Encourages designing primitives that compose, not primitives that require lifecycle management.

## P7. The agent never knows about the channel

Claude Code, when running under `pot`, has no concept of "Telegram," "Horizon," or "the user is on a phone." It calls `pot agent ask "..."` and gets a string back. The channel-routing logic lives in Horizon, where it already exists.

**Why:** keeps the agent prompt small. Lets Horizon evolve (add channels, change formatting) without re-prompting Claude. Lets `pot` be tested without a Telegram account.

## P8. The vault is editable by humans

Frontmatter is YAML, bodies are Markdown, paths are predictable, ULIDs sort. A user editing `task.md` in Obsidian on their phone MUST be a supported workflow. The on-disk format is not a marshalling artifact; it is the UI for desktop.

**Why:** if you can't read and edit it by hand, you've reintroduced a database.

## P9. Borrow ruthlessly, conform sparingly

We freely borrow ideas, conventions, and prompt patterns from Symphony, OpenClaw, Backlog.md, git-issues, and the ACP world. We do not promise wire compatibility with any of them. SPEC.md from `openai/symphony` is reference, not requirement.

**Why:** chasing conformance ties our hands. Reading their code and stealing the good parts does not.

## P10. Reversibility before automation

Anything destructive (rm in a repo, force-push, deleted task files) goes behind an explicit confirmation or a `--yes` flag. Default verbs are reversible.

**Why:** Symphony users report that "validation does not scale" — when an agent ships 14 PRs over a weekend, the review burden is the bottleneck. Reversibility lowers the cost of mistakes, which raises the rate at which the human can let the agent run.
