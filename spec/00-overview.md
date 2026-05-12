# 00 — Overview

## Elevator pitch

> Potentiality is a single static Haskell binary that watches a directory of Markdown task files, claims any task marked `ready`, runs `claude -p` against the named working directory, and writes the result back into the same vault. Mobile and desktop interaction happens through Horizon's existing Telegram bot, which lives on the same vault. No server, no database, no MCP.

## Audience

One person — initially the author. Other solo developers who run their own infra, use Claude Code as their primary coding agent, want their tooling free and open source, and prefer flat files to web apps.

Potentiality is explicitly **not** aimed at teams. A team operating a Linear board and a CI fleet is Symphony's native habitat. See [10-non-goals.md](./10-non-goals.md).

## Topology

```
┌────────────────┐                       ┌─────────────────────────┐
│ phone / desk   │ ─────Telegram────▶   │ Horizon (Dart binary)   │
│                │                       │  · bot                  │
│                │ ──Obsidian / git──▶  │  · bash command tools   │
└────────────────┘                       └────────┬────────────────┘
                                                  │ reads/writes
                                                  ▼
                                         ┌─────────────────────────┐
                                         │ vault/                  │
                                         │  ├ _horizon/...         │
                                         │  └ tasks/<ulid>/        │ ← single source of truth
                                         │     ├ task.md           │
                                         │     ├ transcript.md     │
                                         │     ├ findings.md       │
                                         │     ├ questions/*.md    │
                                         │     ├ inbox/*.md        │
                                         │     └ meta.yaml         │
                                         └────────┬────────────────┘
                                                  │ fsnotify
                                                  ▼
                                         ┌─────────────────────────┐
                                         │ pot do watch (Haskell)  │
                                         │  · claims ready tasks   │
                                         │  · spawns `claude -p`   │
                                         │  · parses stream-json   │
                                         │  · writes back to vault │
                                         └────────┬────────────────┘
                                                  │ stdio
                                                  ▼
                                         ┌─────────────────────────┐
                                         │ claude -p ...           │
                                         │  · Bash, Read, Edit,    │
                                         │    Write, Grep, Task    │
                                         │  · calls `pot agent ask │
                                         │    / note / finding ...`│
                                         └─────────────────────────┘
```

The vault is the only thing that crosses process boundaries. Horizon and `pot` never call each other.

## What makes Potentiality different from Symphony

1. **No server**, no Postgres, no LiveView, no SSH workers. A single binary plus a directory.
2. **The tracker is the vault**, not Linear. Markdown files with YAML frontmatter.
3. **The chat UI is Horizon**, not a dashboard. Telegram + Obsidian.
4. **The agent is Claude Code**, not Codex. Driven by `claude -p --output-format=stream-json`.
5. **Human-in-the-loop is first-class**, not a state-machine afterthought. Claude calls `pot agent ask` mid-task; the question reaches your phone; your reply unblocks it.

## What it borrows from Symphony

- The idea that a task is a self-contained unit with its own workspace.
- The idea that a workflow is versioned and explicit (frontmatter, not config).
- Lifecycle hooks (`before_run`, `after_run`) and budget caps.

## What it borrows from OpenClaw's coding-agent ecosystem

- Chat-thread = session = task as the binding (see [`goldmar/openclaw-code-agent`](https://github.com/goldmar/openclaw-code-agent)).
- `ask` vs `delegate` modes as a knob, not a fork in the codebase.
- Plan approval as a gate, not just a one-time start signal.
- Mid-thread redirection by typing.

## What it borrows from Horizon

- Vault-as-state.
- "Tools are bash command templates, explicitly not MCP" — applied symmetrically: Potentiality's agent-side surface is also bash subcommands.
- Single static binary, distributed via Nix.

See [prior-art/](./prior-art/) for the full investigations behind each.
