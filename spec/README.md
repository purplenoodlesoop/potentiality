# Potentiality — Specification

Draft v0 · 2026-05-13

Potentiality is a Haskell program that takes Markdown task files out of a vault, runs Claude Code against them, and writes the result back. It is the "agent runner" half of an OpenAI-Symphony–style orchestration model, deliberately stripped of every service, database, and protocol Symphony added to serve teams. The chat/management surface is delegated to [purplenoodlesoop/horizon](https://github.com/purplenoodlesoop/horizon), which already runs a Telegram bot on top of the same vault.

## Table of contents

| File | Section |
|---|---|
| [00-overview.md](./00-overview.md) | What Potentiality is, who it is for, the topology in one page |
| [01-philosophy.md](./01-philosophy.md) | Design principles |
| [02-architecture.md](./02-architecture.md) | Topology and task lifecycle |
| [03-vault-layout.md](./03-vault-layout.md) | Task directory schema, frontmatter, state machine |
| [04-cli.md](./04-cli.md) | The `pot` binary: `pot do *` and `pot agent *` |
| [05-hitl.md](./05-hitl.md) | Human-in-the-loop protocol |
| [06-claude-code-backend.md](./06-claude-code-backend.md) | How `pot` drives Claude Code |
| [07-task-kinds.md](./07-task-kinds.md) | `code` / `research` / `design` / `review` / `general` |
| [08-horizon-integration.md](./08-horizon-integration.md) | What Horizon needs to do |
| [09-provisioning.md](./09-provisioning.md) | Nix flake + `core-flake` |
| [10-non-goals.md](./10-non-goals.md) | Things deliberately not built |
| [99-references.md](./99-references.md) | Sources |
| [prior-art/symphony.md](./prior-art/symphony.md) | OpenAI Symphony, in depth |
| [prior-art/openclaw-ecosystem.md](./prior-art/openclaw-ecosystem.md) | caclawphony, openclaw-code-agent, ACP |
| [prior-art/lightweight-trackers.md](./prior-art/lightweight-trackers.md) | Backlog.md, git-issues, Tasks.md, dstask |
| [prior-art/horizon.md](./prior-art/horizon.md) | What Horizon already does |

## Status

This spec is the artifact. Implementation begins after the spec stabilizes. License: to be chosen at implementation time (likely MIT to match Horizon and `core-flake`).

## Conventions used in this spec

- Code paths in `monospace` are real files in real repos we cite; quoted phrases (e.g. "*ticket → walk away → PR*") are paraphrases unless cited.
- "MUST / SHOULD / MAY" follow RFC 2119.
- "Horizon" without qualification means [purplenoodlesoop/horizon](https://github.com/purplenoodlesoop/horizon) at the May 2026 head.
