# 02 — Architecture

## Processes

There are three processes in a steady-state installation; none MUST be running for the others to be useful.

| Process | What it is | When it runs |
|---|---|---|
| **chat client** | Any vault-aware chat bridge — [Horizon](https://github.com/purplenoodlesoop/horizon) (Dart, Telegram-native), [OpenClaw](https://github.com/openclaw/openclaw) with a small skill (multi-channel), or anything that watches files and runs bash | Always-on, user-systemd-service |
| **`pot do watch`** | Haskell binary in daemon mode; fsnotify on `vault/tasks/`, spawns Claude Code per claimed task | Always-on, user-systemd-service (optional; one-shot `pot do run` is also supported) |
| **`claude -p`** | Spawned by `pot` per task, stdio piped to/from `pot` | Per-task; many can run concurrently |

The user, Obsidian, `git`, and other tools touch the same vault as additional readers and writers. See [08-chat-client-integration.md](./08-chat-client-integration.md) for the chat-client contract.

## State

All state is files. The vault has two relevant regions:

```
<vault>/
├── <client-private>/   # Chat-client-owned (allowlist, prompts, channel state, etc.)
└── tasks/              # Potentiality-shared
    └── <ulid>/         # one directory per task; see 03-vault-layout.md
```

`<client-private>/` is the chat client's existing territory (Horizon uses `_horizon/`; an OpenClaw skill would pick its own directory name). `vault/tasks/` is the shared shelf. `pot` only reads and writes under `tasks/`.

## Task lifecycle (happy path)

```
┌──────┐   ┌──────┐   ┌────────────┐   ┌────────┐   ┌──────┐
│inbox │──▶│ready │──▶│in_progress │──▶│  done  │   │blocked│
└──────┘   └──────┘   └────────────┘   └────────┘   └──────┘
                            │
                            └─── (mid-task) ──▶ blocked or back to in_progress
```

Concretely:

1. **inbox** — a task file exists with `status: inbox`. Created by the chat client (e.g. from a Telegram message) or hand-edited (Obsidian). Daemon does nothing.
2. **ready** — human or chat client flips `status: ready`. Daemon sees the change.
3. **in_progress** — daemon claims by atomically committing `status: in_progress` + `agent_owner: <hostname-pid>` to `task.md` frontmatter, then starts the spawn.
4. **done** — Claude exits cleanly with a `result` event; daemon writes status. The chat client picks up the status flip via its own watcher and (optionally) posts a summary to the bound chat thread.
5. **blocked** — Claude calls `pot agent blocked --reason "..."`, or `pot` detects an unrecoverable error.

The `agent_owner` field is the lock. Multiple `pot do watch` instances on the same vault are not supported in v1; if two run, races are detected on claim (the second sees `agent_owner` already set after re-reading the file) and skip the task.

## Sequence: a research task

```
User (chat)                  chat client             vault/                 pot do watch              claude -p
     │                          │                       │                       │                         │
     ├──/task_new research X───▶│                       │                       │                         │
     │                          ├──pot do new ─────────▶│                       │                         │
     │                          │                       │ tasks/<id>/task.md    │                         │
     │                          │                       │ (status: ready)       │                         │
     │                          │                       │◀──fsnotify────────────┤                         │
     │                          │                       │◀──commit claim────────┤                         │
     │                          │                       │ (status: in_progress) │                         │
     │                          │                       │                       ├─spawn─────────────────▶│
     │                          │                       │                       │                         │
     │                          │                       │                       │     (Claude runs;      │
     │                          │                       │                       │      Task subagents,    │
     │                          │                       │                       │      WebSearch, etc.)   │
     │                          │                       │                       │                         │
     │                          │                       │◀──pot agent ask───────────────────────────────┤
     │                          │                       │ questions/001.md      │                         │
     │                          │◀──fsnotify────────────┤                       │                         │
     │◀──chat msg + buttons─────┤                       │                       │                         │
     ├──tap "CLI"──────────────▶│                       │                       │                         │
     │                          ├──write────────────────▶│                      │                         │
     │                          │                       │ questions/001.answer.md                         │
     │                          │                       │                       │                         │
     │                          │                       │                                                  │
     │                          │                       │                       │ pot agent ask unblocks ─▶
     │                          │                       │                       │ (prints "CLI"; claude   │
     │                          │                       │                       │  continues)             │
     │                          │                       │                       │                         │
     │                          │                       │◀──pot agent finding───────────────────────────┤
     │                          │                       │ findings.md appended  │                         │
     │                          │                       │                       │                         │
     │                          │                       │                       │◀──result event─────────┤
     │                          │                       │◀──status: done────────┤                         │
     │                          │◀──fsnotify────────────┤                       │                         │
     │◀──"done" line────────────┤                       │                       │                         │
```

The horizontal arrows that cross between the chat client and `pot do watch` are *exclusively* through the vault. No socket, no pipe, no syscall between them.

## Concurrency

- **Within one task**: one Claude subprocess, one `pot` parent reading its stdout, parallelism happens *inside* Claude (it spawns its own subagents via the `Task` tool).
- **Across tasks**: `pot do watch` spawns N parallel Claude processes up to `max_concurrent` (default 3). Each gets its own working directory (the task's `repo` field, possibly inside a `git worktree`).
- **Across `pot do watch` instances**: not supported. Run one watcher per vault.
- **Across hosts**: not supported. Symphony's SSH-worker model is explicitly dropped (see [10-non-goals.md](./10-non-goals.md)).

## Failure model

| Failure | What survives | Recovery |
|---|---|---|
| `claude -p` crashes | task dir on disk, frontmatter, transcript | `pot do watch` sees process exit, writes `status: blocked`, reason includes last 20 lines of transcript |
| `pot do watch` crashes | everything | On restart, scan `vault/tasks/`; for any `status: in_progress` with `agent_owner` matching this host's prior pid, decide: resume via `claude --resume <session_id>` or mark blocked. Default: mark blocked, let human re-`ready`. |
| Chat client crashes | everything | On restart, the client re-watches the vault; pending questions/plans/answers are still on disk; user-facing latency = restart time only |
| Host crashes | everything | Same as both above |
| Vault git push conflict | local vault | `pot` does not push automatically; it commits. Conflicts are a human concern. |

## Process supervision

Both the chat client and `pot do watch` are designed to run as **user-level systemd services** under NixOS (or launchd on macOS). `Restart=on-failure`, `RestartSec=5`. No PID files, no lock files — they cooperate through `vault/tasks/*/meta.yaml#agent_owner`.

## Data flow summary

| From | To | Vehicle |
|---|---|---|
| Chat surface → vault | Chat client (writes files) | bash tool / skill / slash command |
| Vault → chat surface | Chat client (reads files via fsnotify or polling) | bash tool / skill / slash command |
| Vault → Claude | `pot do watch` spawns claude with task body | stdin/argv |
| Claude → Vault | Claude calls `pot agent *` via Bash tool | `pot` writes files |
| Claude → `pot` | stream-json on stdout | parsed by `pot do watch` |
| `pot` → Claude | stream-json on stdin (when `--input-format=stream-json`) | written by `pot do watch` (v2; v1 uses argv) |
| User → vault | Obsidian / Working Copy / `vim` | direct file edit |
| Vault → User | Obsidian / `cat` / chat surface (via chat client) | direct file read |
