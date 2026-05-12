# 02 — Architecture

## Processes

There are three processes in a steady-state installation; none MUST be running for the others to be useful.

| Process | What it is | When it runs |
|---|---|---|
| **Horizon** | Dart binary; Telegram bot + bash-tool harness on a Markdown vault | Always-on, user-systemd-service |
| **`pot do watch`** | Haskell binary in daemon mode; fsnotify on `vault/tasks/`, spawns Claude Code per claimed task | Always-on, user-systemd-service (optional; one-shot `pot do run` is also supported) |
| **`claude -p`** | Spawned by `pot` per task, stdio piped to/from `pot` | Per-task; many can run concurrently |

The user, Obsidian, `git`, and other tools touch the same vault as additional readers and writers.

## State

All state is files. The vault has two relevant regions:

```
<vault>/
├── _horizon/           # Horizon-owned (capabilities, system prompts, allowlist, etc.)
└── tasks/              # Potentiality-shared
    └── <ulid>/         # one directory per task; see 03-vault-layout.md
```

`vault/_horizon/` is Horizon's existing territory; `vault/tasks/` is the shared shelf.

## Task lifecycle (happy path)

```
┌──────┐   ┌──────┐   ┌────────────┐   ┌────────┐   ┌──────┐
│inbox │──▶│ready │──▶│in_progress │──▶│  done  │   │blocked│
└──────┘   └──────┘   └────────────┘   └────────┘   └──────┘
                            │
                            └─── (mid-task) ──▶ blocked or back to in_progress
```

Concretely:

1. **inbox** — a task file exists with `status: inbox`. Either created by Horizon (Telegram message) or hand-edited (Obsidian). Daemon does nothing.
2. **ready** — human or Horizon flips `status: ready`. Daemon sees the change.
3. **in_progress** — daemon claims by atomically committing `status: in_progress` + `agent_owner: <hostname-pid>` to `task.md` frontmatter, then starts the spawn.
4. **done** — Claude exits cleanly with a `result` event; daemon writes status, optionally posts a summary line to the bound Telegram thread.
5. **blocked** — Claude calls `pot agent blocked --reason "..."`, or `pot` detects an unrecoverable error.

The `agent_owner` field is the lock. Multiple `pot do watch` instances on the same vault are not supported in v1; if two run, races are detected on claim (the second sees `agent_owner` already set after re-reading the file) and skip the task.

## Sequence: a research task

```
User (Telegram)              Horizon                 vault/                 pot do watch              claude -p
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
     │◀──Telegram msg + buttons─┤                       │                       │                         │
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
     │◀──Telegram "done" line───┤                       │                       │                         │
```

The horizontal arrows that cross between Horizon and `pot do watch` are *exclusively* through the vault. No socket, no pipe, no syscall between them.

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
| Horizon crashes | everything | On restart, Horizon re-watches vault; pending questions/plans/answers are still on disk; user-facing latency = restart time only |
| Host crashes | everything | Same as both above |
| Vault git push conflict | local vault | `pot` does not push automatically; it commits. Conflicts are a human concern. |

## Process supervision

Both Horizon and `pot do watch` are designed to run as **user-level systemd services** under NixOS (or launchd on macOS). `Restart=on-failure`, `RestartSec=5`. No PID files, no lock files — they cooperate through `vault/tasks/*/meta.yaml#agent_owner`.

## Data flow summary

| From | To | Vehicle |
|---|---|---|
| Telegram → vault | Horizon (writes files) | bash command templates |
| Vault → Telegram | Horizon (reads files via fsnotify) | bash command templates |
| Vault → Claude | `pot do watch` spawns claude with task body | stdin/argv |
| Claude → Vault | Claude calls `pot agent *` via Bash tool | `pot` writes files |
| Claude → `pot` | stream-json on stdout | parsed by `pot do watch` |
| `pot` → Claude | stream-json on stdin (when `--input-format=stream-json`) | written by `pot do watch` (v2; v1 uses argv) |
| User → vault | Obsidian / Working Copy / `vim` | direct file edit |
| Vault → User | Obsidian / `cat` / Telegram (via Horizon) | direct file read |
