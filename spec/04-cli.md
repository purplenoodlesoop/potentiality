# 04 — CLI

`pot` is the single binary. It has two top-level groups:

- **`pot do *`** — orchestrator/human side. Things you run from a shell or that Horizon shells out to.
- **`pot agent *`** — agent side. Things Claude Code invokes through its built-in `Bash` tool.

The split is for clarity and discoverability; there is no enforcement. A human can run `pot agent ask` to test the IPC; an agent could technically run `pot do list`. The convention guides users, not the binary.

## Global flags

```
pot [--vault PATH] [--config PATH] [--log-level LEVEL] [--version] [--help]
```

| Flag | Default | Notes |
|---|---|---|
| `--vault PATH` | `$POTENTIALITY_VAULT` or `./vault` | Root vault directory |
| `--config PATH` | `$XDG_CONFIG_HOME/potentiality/config.yaml` | Optional global config |
| `--log-level` | `info` | `trace` / `debug` / `info` / `warn` / `error` |
| `--version` | — | Prints semver |

For `pot agent *` invocations, `--vault` is not needed — the task is identified by `$POTENTIALITY_TASK_DIR` set by the spawner.

## `pot do *` — orchestrator side

### `pot do run <task-file>`

Run a single task to completion in the foreground. Synchronous; exits 0 on success, non-zero on blocked/error.

```
pot do run vault/tasks/01HE.../task.md
```

Useful for ad-hoc execution, CI, and debugging. Does *not* require `pot do watch` to be running.

### `pot do watch [<vault>]`

Daemon mode. Watches `<vault>/tasks/` with fsnotify; for any task with `status: ready` and no `agent_owner`, claims it and spawns Claude. Up to `--max-concurrent` in flight.

```
pot do watch --max-concurrent 3 --max-cost-usd-per-task 5
```

| Flag | Default | Notes |
|---|---|---|
| `--max-concurrent N` | `3` | Concurrent task limit |
| `--max-cost-usd-per-task` | unset | Per-task budget cap (passed to claude) |
| `--max-cost-usd-per-day` | unset | Stop claiming new tasks once daily total reaches this |
| `--raw-transcripts` | off | Also write `transcript.jsonl` |
| `--dry-run` | off | Claim tasks but don't actually spawn claude; useful for testing |

Designed to be run under systemd-user.

### `pot do new [--kind K] [--title T] [--mode M] [--repo R] -- <body...>`

Create a new task file. Generates a ULID, writes `vault/tasks/<ulid>/task.md` with frontmatter.

```
pot do new --kind research --title "Investigate X" -- "Find out how X works ..."
```

This is the command Horizon will mostly use. Returns the new ULID on stdout.

| Flag | Default | Notes |
|---|---|---|
| `--kind` | `general` | One of: `code`, `research`, `design`, `review`, `general` |
| `--title` | first 60 chars of body | One-line title |
| `--mode` | kind-specific (see 07) | `ask` or `delegate` |
| `--repo` | `$PWD` | Working dir for the spawn |
| `--status` | `inbox` | Starting status; pass `ready` to skip triage |
| `--priority` | `med` | `low` / `med` / `high` |
| `--budget-usd` | unset | Per-task budget |

### `pot do ready <id>`

Promote `inbox` → `ready` for the named task.

### `pot do list [--filter ...] [--format FMT]`

List tasks.

```
pot do list --status in_progress --format json
pot do list --kind research --status done --since 24h
```

| Flag | Notes |
|---|---|
| `--status S` | repeatable; filter |
| `--kind K` | repeatable |
| `--since DURATION` | e.g. `1h`, `24h`, `7d` |
| `--format` | `table` (default), `json`, `tsv` |

### `pot do show <id>`

Show task details: frontmatter, body, last 20 lines of transcript, pending questions, status.

```
pot do show 01HE... [--format json] [--tail N]
```

### `pot do tail <id>`

Tail `transcript.md` (and `transcript.jsonl` if `--raw`).

```
pot do tail 01HE... [--follow] [--raw]
```

### `pot do kill <id>`

Cancel a running task. Touches `vault/tasks/<id>/CANCEL`; the watching `pot do watch` instance sends SIGTERM, then SIGKILL after 5s.

### `pot do answer <id> <question-num> -- <answer...>`

Manually answer a pending question from the CLI (Horizon's normal path is to write the answer file directly).

```
pot do answer 01HE... 1 -- "CLI"
```

### `pot do approve <id> [--revise "..."] [--reject]`

Respond to a pending plan (`mode: delegate`).

```
pot do approve 01HE...                  # approve
pot do approve 01HE... --revise "do X instead of Y"
pot do approve 01HE... --reject
```

### `pot do gc [--older-than DURATION]`

Remove `transcript.jsonl` files from `done` tasks older than the given duration. Keeps `task.md`, `meta.yaml`, `findings.md`, `transcript.md`. Default: 30d.

## `pot agent *` — agent side

These commands MUST be invoked from inside a `pot do run` / `pot do watch` spawned process, where `$POTENTIALITY_TASK_DIR` is set. Outside that environment they error.

Claude's system prompt (set by `pot` via `--append-system-prompt`) tells it which to call when.

### `pot agent ask <question> [--options "a,b,c"] [--urgency normal|high] [--timeout SECONDS]`

Block until a human responds. Writes `questions/NNN.md`, waits for `questions/NNN.answer.md` (inotify), prints the answer (trimmed) to stdout.

```
pot agent ask "Should this be a CLI or a server?" --options "CLI,server,both"
```

Exit codes:

| Code | Meaning |
|---|---|
| `0` | Answer received; printed to stdout |
| `124` | Timeout (only if `--timeout` set) |
| `130` | Task cancelled (CANCEL file appeared while waiting) |

### `pot agent status <one-line>`

Update `meta.yaml#current_step`. Fire-and-forget.

```
pot agent status "spawning 3 subagents for investigation"
```

### `pot agent note <text>`

Append a manual note to `transcript.md` (separate from auto-logged tool output).

### `pot agent finding <text>`

Append to `findings.md`. Used for `kind: research` / `kind: design` to build the output document. Text is appended verbatim; agent is responsible for headers/structure.

### `pot agent plan <markdown>`

Write `plan.md` (overwrites previous), block on user approval. Returns:

- `approved\n` on stdout, exit 0 → proceed with the plan
- `revise: <feedback>\n` on stdout, exit 0 → revise and re-`pot agent plan`
- `rejected\n` on stdout, exit 1 → task done, no work

### `pot agent done [--message "..."]`

Mark `status: done`. Implicit when the spawned claude exits cleanly with a `result` event; explicit call is for early termination.

### `pot agent blocked --reason "..."`

Mark `status: blocked`. Used when Claude cannot proceed and needs human intervention beyond a yes/no answer.

## Subcommand summary table

| Group | Verb | Blocking? | Writes | Reads | Used by |
|---|---|---|---|---|---|
| do | `run` | yes | everything in task dir | task.md | human, CI |
| do | `watch` | yes (long) | many tasks | vault/tasks/ | systemd, human |
| do | `new` | no | task.md | — | Horizon, human |
| do | `ready` | no | task.md (frontmatter) | task.md | Horizon, human |
| do | `list` | no | — | tasks/ | Horizon, human |
| do | `show` | no | — | task dir | Horizon, human |
| do | `tail` | yes (follow) | — | transcript.md | Horizon, human |
| do | `kill` | no | CANCEL | — | Horizon, human |
| do | `answer` | no | questions/NNN.answer.md | questions/NNN.md | Horizon, human |
| do | `approve` | no | meta.yaml | plan.md | Horizon, human |
| do | `gc` | no | (removes files) | tasks/ | cron, human |
| agent | `ask` | **yes** | questions/NNN.md | questions/NNN.answer.md | claude |
| agent | `status` | no | meta.yaml | — | claude |
| agent | `note` | no | transcript.md | — | claude |
| agent | `finding` | no | findings.md | — | claude |
| agent | `plan` | **yes** | plan.md | meta.yaml#plan_decision | claude |
| agent | `done` | no | task.md (frontmatter) | — | claude |
| agent | `blocked` | no | task.md (frontmatter) | — | claude |

## Exit codes

Exit codes are uniform across the binary:

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Generic error |
| 2 | Argument parse error |
| 64 | Task not found |
| 65 | Task in wrong state for requested op |
| 66 | Budget exceeded |
| 124 | Timeout |
| 130 | Cancelled (SIGTERM or CANCEL file) |

## Environment variables

| Var | Set by | Read by | Purpose |
|---|---|---|---|
| `POTENTIALITY_VAULT` | user | `pot do *` | Default vault root |
| `POTENTIALITY_TASK_DIR` | `pot do watch` / `pot do run` (in spawned child) | `pot agent *` | Identifies the task to agent-side commands |
| `POTENTIALITY_SESSION` | `pot do watch` / `pot do run` (in spawned child) | `pot agent *`, claude logs | ULID of the task |
| `ANTHROPIC_API_KEY` | user | claude (forwarded) | API auth |
| `CLAUDE_CODE_OAUTH_TOKEN` | user (alt) | claude (forwarded) | Long-lived subscription token |
| `PATH` | `pot` adds itself in front before spawning claude | claude → Bash | Lets claude find `pot agent *` |
