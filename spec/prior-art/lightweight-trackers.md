# Prior art — Lightweight markdown-as-database trackers

Survey of the "tasks live as files in a git repo" pattern. These are the projects whose conventions Potentiality borrows directly.

## The cluster

The pattern crystallized in 2025-26 into roughly five projects worth reading:

### Backlog.md

[Repo.](https://github.com/MrLesk/Backlog.md) [HN.](https://news.ycombinator.com/item?id=44483530)

The flagship example. Tasks are Markdown files with YAML frontmatter under `backlog/`. Every change is a git commit. Two UIs: terminal Kanban (`backlog board`) and a React web view (`backlog browser`). Brew / npm / Nix install. Self-described as "a tool for managing project collaboration between humans and AI Agents in a git ecosystem"; ships an MCP server for Claude Code / Codex / Gemini.

### dstask

[Repo.](https://github.com/naggie/dstask)

Single-Go-binary. Taskwarrior-like CLI ergonomics, git as sync protocol (no special server), one Markdown note page per task. The "predecessor" to the modern wave — same idea, less coding-agent integration.

### git-issues

[Show HN.](https://news.ycombinator.com/item?id=47973644)

One Go binary, no DB, no server. Issues are YAML-frontmatter `.md` files in `.issues/`. Auto-generates a `.agent.md` context file. CLI verbs: `issues next`, `issues claim`, `issues done` — explicitly modeled on an agent loop.

### Tasks.md

[Repo.](https://github.com/BaldissaraMatheus/Tasks.md)

Single-Docker self-hosted. Lanes = directories, cards = `.md` files. PWA-installable for mobile.

### taskmd

[Medium write-up.](https://medium.com/@driangle/taskmd-task-management-for-the-ai-era-92d8b476e24e)

One markdown file per task in `./tasks/`. Designed explicitly for Claude Code to read and update.

### Honorable mentions

- [imdone](https://github.com/imdone/imdone) — embeds tasks in code comments and Markdown.
- [veggiemonk/backlog](https://github.com/veggiemonk/backlog) — minimalist Go alternative.
- [Obsidian Tasks](https://taskforge.md/blog/obsidian-project-management/), [Obsidian Task Board plugin](https://www.obsidianstats.com/plugins/task-board) — vault-resident, aggregated via plugin.
- [AGENTS.md](https://agents.md/) — convention, not a tool, for the agent-readable "README of an agent project."

## What they have in common

1. **File-per-task, YAML-frontmatter-for-state, Markdown-body-for-description.** This is the universal shape.
2. **Git is the audit log.** No separate event sourcing, no append-only log file, no DB-side history table.
3. **CLI verbs match an agent's mental model**: `next`, `claim`, `start`, `done`, `block`.
4. **Mobile editing path** is "sync the directory to your phone" (Obsidian, Working Copy, Termux). No native mobile app needed.
5. **No backend service.** A single binary or a single Docker container.

## Backlog.md's verbs (the closest reference for Potentiality)

```
backlog task create "Title" -d "description"     → new .md file
backlog board                                     → terminal Kanban
backlog browser                                   → React web view (localhost)
backlog next                                      → suggest next task
backlog start <id>                                → flip status
backlog complete <id>                             → flip status
backlog list --status doing
```

Potentiality's `pot do *` verbs intentionally mirror this: `pot do new`, `pot do ready`, `pot do list`, `pot do show`.

## What we adopt directly

- **File per task, YAML frontmatter, Markdown body.** Identical.
- **Git is the audit log.** Identical.
- **`next` / `claim` / `done` style verbs**, renamed to `do new` / `do ready` / `do list` / `do show` / (implicit done on agent completion).
- **No backend service.** Identical.

## What we add that none of them have

1. **`questions/` and `plan.md`.** Backlog.md / git-issues / Tasks.md have no native HITL channel — they assume the human reads tasks and writes responses by hand. Potentiality has a structured agent-asks-human protocol.
2. **`findings.md` for research/design outputs.** None of the existing tools have a "non-code output" convention; they're all coding-task oriented.
3. **Telegram bridge** (via Horizon) for mobile interaction without an Obsidian sync.
4. **Per-task budget caps and cost tracking** (`meta.yaml#total_cost_usd`).
5. **Per-task agent spawn semantics** (kind, mode, permission_mode, allowed_tools) baked into frontmatter — these are all Claude-Code-specific runtime concerns the markdown-tracker tools don't model.

## Mobile-editing field notes

- **Working Copy on iOS** is the de-facto git client. Integrates with Obsidian via the Files app and with Apple Shortcuts. ([Obsidian forum reference.](https://forum.obsidian.md/t/mobile-setting-up-ios-git-based-syncing-with-mobile-app-using-working-copy/16499))
- **Termux + git** on Android.
- **Obsidian Mobile** with the Git plugin syncs the vault directly. ([Megan Sullivan's writeup](https://meganesulli.com/blog/sync-obsidian-vault-iphone-ipad/).)
- **GitHub mobile app** for read-only browsing of issues.

What works on mobile: editing one file at a time, browsing, light writes. What's clunky: merge conflicts, attachments, the auth dance. **Most people who try git-on-phone abandon writes and use it read-only**, which is why a chat-style write surface (Telegram via Horizon) is attractive: typing into Telegram is faster than typing into a git client.

## Heavyweight alternatives we explicitly reject

Documented in [10-non-goals.md](../10-non-goals.md). Summary:

| Tool | Why rejected |
|---|---|
| Kaneo | Multi-service (Hono + React + Postgres) for what should be a directory of files; data lives in DB not repo; SPA optimized for humans, not for agents reading state |
| Vikunja | Lighter than Kaneo (single Go binary + SQLite) but still a tracker app with its own data model, not files |
| Planka / Wekan | Trello-style Kanban; ~12k stars but full app stack |
| Plane | 7+ containers (FE, API, workers, Postgres, Redis, MinIO, nginx) — heavy |
| Focalboard | Abandoned (Mattermost folded it back in 2023) |
| Linear self-hosted | Doesn't exist |
| GitHub Projects v2 | API works but GitHub Apps can't access user-level v2 projects (only PATs); also tethers a self-hosted system to a SaaS |
| Plain GitHub Issues | Workable as a mirror, but loses custom workflow states; UI good on mobile |

The criterion that ruled all of them out: **the data lives somewhere other than the repo.** That's where the vault-based design wins.

## The "agent's todo IS the tracker" pattern

Worth noting because it's an alternative we considered and rejected:

Claude Code persists tasks to `~/.claude/tasks` as durable state with DAG dependencies. Community patterns include `.llm/todo.md` + a `/todo-all` slash command, [continuous-claude](https://github.com/AnandChowdhary/continuous-claude) (the "Ralph loop"), `SHARED_TASK_NOTES.md` handoff files, and the cross-vendor `AGENTS.md` convention.

This is fine for *intra-task* state (Claude's own scratchpad while working on one thing) but not for *inter-task* state (the user's roadmap). Potentiality keeps them separate: the agent's intra-task todos are managed by Claude internally; the user's task queue is `vault/tasks/`.

## Source citations

See [99-references.md](../99-references.md#lightweight-markdown-trackers) for the full reference list.
