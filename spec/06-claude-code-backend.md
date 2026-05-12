# 06 — Claude Code backend

`pot` drives Claude Code as a child process per task. This document specifies exactly how.

## Why headless `claude -p` and not the SDK

- The Claude Agent SDK exists only in TypeScript and Python; we are Haskell.
- The CLI is the lowest-level entrypoint Anthropic ships; the SDK is sugar over the same agentic loop.
- Shelling out is language-agnostic and matches Horizon's own design (which shells out to OpenAI-compatible HTTP).
- One static binary in PATH is simpler to provision via Nix than an embedded language runtime.

## Spawn invocation

```
claude
  -p
  --output-format stream-json
  --input-format stream-json        # only when v2 redirect channel is enabled
  --include-partial-messages
  --bare                            # skip auto-discovery (hooks, plugins, CLAUDE.md, MCP)
  --append-system-prompt <prompt>   # see "System prompt" below
  --allowedTools <comma-separated>  # see "Allowed tools" below
  --permission-mode <mode>          # see "Permission mode"
  [--max-budget-usd N]              # per-task cap if frontmatter sets budget_usd
  [--session-id <ulid>]             # bind to task ULID for resumability
  [--resume <session-id>]           # on restart after crash; v2
  --                                # end of flags
  <task body>                        # the user's prompt
```

Working directory: the task's `repo` field (default `$PWD` at task creation). If `repo` is a git repo and `worktree: true` is set in frontmatter (default for `kind: code` in v2), spawn in a fresh `git worktree` rooted at `vault/tasks/<id>/.worktree/`.

Environment, beyond what the user already has:

| Var | Value |
|---|---|
| `POTENTIALITY_TASK_DIR` | absolute path to `vault/tasks/<ulid>/` |
| `POTENTIALITY_SESSION` | the ULID |
| `PATH` | `<pot's own dir>:$PATH` so `pot agent *` resolves first |

`--bare` is important: it prevents Claude Code from auto-loading the user's personal hooks, MCP servers, skills, and CLAUDE.md, which would make runs non-reproducible and could leak unrelated context. The task body and the appended system prompt are the only inputs.

## System prompt (appended)

`pot` injects an `--append-system-prompt` block. The content depends on `kind` (see [07-task-kinds.md](./07-task-kinds.md)) but always includes the same shared preamble:

```
You are running inside the Potentiality orchestrator. Your task is described
in the user message. You have access to a `pot` CLI in your PATH, which you
invoke through the Bash tool to interact with the orchestrator and the human
on the other side.

Tools:
  pot agent ask "<question>" [--options "a,b,c"]
      Block until a human responds; print the answer to stdout.
      Use when you need a human decision you cannot make yourself.

  pot agent status "<one-line>"
      Tell the user what you are currently doing. Fire-and-forget.

  pot agent note "<text>"
      Add a note to the transcript that the user can read later.

  pot agent finding "<markdown>"
      [research/design only] Append synthesized findings to the output document.

  pot agent plan "<markdown>"
      [delegate mode only] Propose a plan; block until approved/revised/rejected.

  pot agent done [--message "<text>"]
      Mark the task complete.

  pot agent blocked --reason "<text>"
      Mark the task blocked; explain what the user must do.

Rules:
  - Prefer `pot agent ask` with `--options` over free-form questions when the
    answer space is bounded (2-4 options).
  - Call `pot agent status` whenever you start a long step (subagent, websearch,
    multi-file edit).
  - Never call `pot agent finding` for `kind: code`. Use Edit/Write to modify the
    repo instead.
  - Never speculate about Telegram, channels, users by name, or message
    formatting — `pot agent ask` returns a plain string answer.
```

`kind`-specific addenda are documented in [07-task-kinds.md](./07-task-kinds.md).

## Allowed tools

`--allowedTools` is computed from the task's `kind` plus any `allowed_tools:` override in frontmatter.

| kind | Default `--allowedTools` |
|---|---|
| `code` | `Bash(pot agent *), Bash, Read, Edit, Write, Grep, Glob` |
| `research` | `Bash(pot agent *), Read, WebSearch, WebFetch, Task` |
| `design` | `Bash(pot agent *), Read, WebSearch, WebFetch, Task, Write` |
| `review` | `Bash(pot agent *), Read, Grep, Glob` |
| `general` | `Bash(pot agent *), Read` |

For `kind: code`, the unrestricted `Bash` is included because the agent needs to run tests, build commands, git, etc. For other kinds, `Bash` is restricted to `pot agent *` patterns so the agent cannot accidentally execute arbitrary shell.

## Permission mode

| kind / mode | `--permission-mode` |
|---|---|
| `code` + `mode: delegate` | `acceptEdits` |
| `code` + `mode: ask` | `default` |
| `research` / `design` / `review` / `general` | `default` |

Frontmatter `permission_mode:` overrides.

## stream-json events `pot` MUST handle

Claude Code emits line-delimited JSON on stdout. Each line is one event. `pot` reads with a conduit / streaming pipeline; the relevant event types are:

### `system` / `init`
First event. Carries `session_id`, `model`, `tools`, `mcp_servers`, plugins.

```json
{"type":"system","subtype":"init","session_id":"...","model":"claude-opus-4-7","tools":[...],"mcp_servers":[],"plugins":[],"plugin_errors":[]}
```

Action: write `meta.yaml#claude_session_id`, capture `model`.

### `stream_event` with `message_delta` / `text_delta`
Token-level text deltas as the assistant produces output.

```json
{"type":"stream_event","event":{"type":"message_delta","delta":{"type":"text_delta","text":"..."}},"session_id":"..."}
```

Action: append to `transcript.md` (within the current assistant turn); optionally to `transcript.jsonl`.

### `stream_event` with `content_block_start` (tool_use)
Claude starts a tool call.

```json
{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","id":"...","name":"Bash","input":{"command":"pot agent ask ..."}}}}
```

Action: append a `## ... — tool: Bash` section to `transcript.md`.

### `stream_event` with `content_block_stop` + tool_result
Tool completed.

Action: append result to transcript (truncate long results to 4 KB in `transcript.md`).

### `system` / `api_retry`
Retryable API error.

```json
{"type":"system","subtype":"api_retry","attempt":1,"max_retries":3,"retry_delay_ms":1000,"error_status":429}
```

Action: log to `transcript.md` as a warning; let claude handle the retry.

### `result` (final)
Terminal event.

```json
{"type":"result","subtype":"success","session_id":"...","total_cost_usd":0.42,"usage":{"input_tokens":12345,"output_tokens":8765,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"stop_reason":"end_turn"}
```

Action: update `meta.yaml` (`total_cost_usd`, `tokens`, `finished_at`), write `status: done` to `task.md`, log a closing line to `transcript.md`. If `subtype == "error"`, instead write `status: blocked` with the error.

### Unknown event types
Log to `transcript.jsonl` if enabled; otherwise ignore. Do not crash on unknown event types — Claude Code evolves.

## Session resumption

`pot` records `claude_session_id` per task. On `pot do watch` restart, for any task with `status: in_progress`:

- If the original claude process is still alive (pid still owned by this user, name `claude`): adopt it (re-attach stdout). v2.
- Otherwise: choose between `claude --resume <id>` (continue mid-task) and marking blocked. Default in v1: mark blocked, log, let human decide. v2: configurable per-task `on_crash: resume | block`.

## Concurrency

Multiple claude subprocesses run in parallel under one `pot do watch`. Each has:

- Its own stdio pipes (no contention).
- Its own working directory (or worktree).
- Its own `POTENTIALITY_TASK_DIR` env var.
- A unique `--session-id` (the task ULID).

Shared state (`~/.claude/projects/`, `~/.claude/settings.json`) is read-only from `pot`'s perspective; we never write to it. The `--bare` flag avoids reading from it for hooks/MCP/skills/CLAUDE.md.

## Cost tracking

Cost is read from the `result` event's `total_cost_usd` field and written to `meta.yaml`. `pot do watch --max-cost-usd-per-day N` keeps a rolling sum (across all tasks) in `<vault>/_potentiality/cost.yaml`; when N is reached, new claims pause until midnight UTC.

Per-task budget: `task.md` frontmatter `budget_usd:` → `--max-budget-usd` flag → claude refuses to continue past the cap.

## Authentication

`pot` forwards whichever auth env var the user has set: `ANTHROPIC_API_KEY` (Console API), `CLAUDE_CODE_OAUTH_TOKEN` (long-lived subscription token), or the cloud-provider variants (`CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`). `pot` does not parse, validate, or store these — they're passed through verbatim. If none are set, claude fails on first request and `pot` marks the task blocked with that error.
