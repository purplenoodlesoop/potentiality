# 03 — Vault layout

This document defines the on-disk schema. It is the contract between the chat client (Horizon, OpenClaw, …), `pot`, and humans editing files by hand. Backwards-incompatible changes to this layout MUST bump a version field in `task.md` frontmatter.

## Top-level shape

```
<vault>/
├── <client-private>/         # owned by the chat client (e.g. _horizon/, _openclaw/, …)
└── tasks/
    └── <ulid>/               # one directory per task
        ├── task.md           # required; the task itself
        ├── meta.yaml         # session bookkeeping (claude session id, telegram binding, ...)
        ├── transcript.md     # append-only human-readable log of what claude did
        ├── transcript.jsonl  # append-only raw stream-json events (optional, for debugging)
        ├── plan.md           # latest proposed plan (delegate mode)
        ├── findings.md       # output for kind=research / kind=design
        ├── inbox/            # user-injected messages (mid-task redirects, v2)
        │   └── <iso-ts>.md
        ├── questions/        # claude→user asks
        │   ├── 001.md        # the question
        │   └── 001.answer.md # user's reply (presence unblocks `pot agent ask`)
        └── CANCEL            # presence ⇒ SIGTERM the claude process
```

Files marked optional are not created until the relevant kind of activity happens. A task dir with only `task.md` and `meta.yaml` is valid and common.

## ULIDs as task IDs

Task directories are named with [ULID](https://github.com/ulid/spec) strings (26 chars, base32, time-ordered). Rationale: time-sorted so `ls -1` shows oldest first; URL-safe; collision-free under concurrent writes from a chat client and a human.

`pot do new` generates the ULID (whether invoked by the chat client or a human shell). Hand-edited tasks MAY use any unique directory name (no enforcement).

## `task.md`

Required. YAML frontmatter + Markdown body. Body is the task prompt (what the agent should do); frontmatter is the metadata.

### Required frontmatter fields

```yaml
---
schema: 1                    # int; bump for breaking changes
kind: research               # code | research | design | review | general
status: ready                # inbox | ready | in_progress | done | blocked
title: "Investigate X"       # one-line summary; shown in lists
created: 2026-05-13T10:00:00Z
---
```

### Optional frontmatter fields

```yaml
mode: ask                    # ask | delegate; default depends on kind (see 07-task-kinds.md)
repo: ~/code/my-app          # working directory for the spawn; default $PWD when task created
priority: med                # low | med | high; default med
agent_owner: null            # set by daemon when claimed; "<hostname>:<pid>"
depends_on: []               # list of ULIDs that must be `done` first
budget_usd: 5.00             # caps `claude --max-budget-usd`; default unset (no cap)
permission_mode: acceptEdits # default | acceptEdits | plan | bypassPermissions; default depends on kind
allowed_tools:               # overrides kind default; comma-joined into `--allowedTools`
  - Bash(pot agent *)
  - Read
  - Edit
  - WebSearch
plan_approval: required      # required | skipped; for mode=delegate
telegram:                    # filled by the chat client when task is bot-created;
  chat_id: 12345             # field name is conventional, not enforced — a Slack
  thread_id: 678             # client might write a `slack:` block instead
labels: []                   # free-form tags, surfaced in lists
```

### Body

The body is the prompt. It is sent to Claude verbatim as the initial user message. There is no preprocessing; the agent reads what you wrote. For `kind: research`, the body is the research question. For `kind: code`, it's the engineering task. For `kind: review`, the path or PR to review.

## `meta.yaml`

Session bookkeeping. Written by `pot`; not authoritative (everything here can be derived from other files, but it's faster to read).

```yaml
session: 01HE...             # mirrors directory name
claude_session_id: ...       # captured from claude's `system/init` event
started_at: 2026-05-13T...
finished_at: null
current_step: "fanning out subagents"   # set by `pot agent status`
last_tool_call: WebSearch    # optional, for tail UX
total_cost_usd: 0.42         # rolling sum from result events
tokens:
  input: 12345
  output: 8765
  cache_read: 0
```

## `transcript.md`

Append-only human-readable log. Each entry is a fenced section:

```markdown
## 2026-05-13T10:01:23Z — assistant
Reasoned briefly about X, then called WebSearch...

## 2026-05-13T10:01:25Z — tool: WebSearch
query: "OpenAI Symphony architecture"

## 2026-05-13T10:01:30Z — tool result: WebSearch
(truncated to 4 KB)
...

## 2026-05-13T10:02:01Z — `pot agent note`
"Found three relevant projects: caclawphony, openclaw-code-agent, ACP."
```

`pot` MAY truncate long tool results to `transcript.md` (full content goes to `transcript.jsonl` if enabled). Truncation marker: `(truncated to N bytes — see transcript.jsonl)`.

## `transcript.jsonl`

Optional raw stream-json log, one event per line. Enabled by `pot do watch --raw-transcripts` or task frontmatter `raw_transcript: true`. Useful for debugging; off by default for disk hygiene.

## `plan.md`

Used when `mode: delegate`. Written by Claude via `pot agent plan "..."`. Format is free-form Markdown. The chat client detects creation and surfaces it for `Approve / Revise / Reject`. The user's decision is recorded by the client writing into `meta.yaml#plan_decision`.

```yaml
# meta.yaml after approval
plan_decision: approved      # approved | revise | rejected
plan_revision: ""            # set when decision = revise
plan_decided_at: 2026-05-13T10:15:00Z
```

`pot agent plan` blocks until `plan_decision` is set.

## `findings.md`

Used for `kind: research` and `kind: design`. Append-only. The agent writes via `pot agent finding "..."`. Format is free-form Markdown; convention is sections under `## ` headers.

## `inbox/`

Reserved for v2. Mid-task redirect channel. Files are timestamp-named Markdown documents; `pot` streams them into Claude via stream-json stdin injection. Empty in v1.

## `questions/`

Each question is a pair: `NNN.md` (written by Claude via `pot agent ask`) and `NNN.answer.md` (written by the chat client / user). `NNN` is zero-padded 3-digit, monotonically increasing per task.

```yaml
# questions/001.md
---
asked_at: 2026-05-13T10:05:00Z
urgency: normal              # normal | high
options:                     # optional; if present, rendered as buttons by the chat client
  - CLI
  - server
  - both
---

Which shape should Potentiality take? See task body for context.
```

```markdown
# questions/001.answer.md
CLI
```

Answer file body is the answer verbatim. Whitespace-trimmed by `pot agent ask` before being returned to Claude. For multi-line answers (no options), the chat client writes the entire user reply.

## `CANCEL`

Empty file. Presence signals "kill this task." `pot` watches each in-progress task dir for this file; on creation, sends SIGTERM to the claude process, then SIGKILL after 5s grace. Writes `status: blocked, reason: cancelled`.

## State machine

```
                 (chat client /
                  hand edit)
inbox ────────────────────────▶ ready
                                  │
                                  │ (pot do watch claims)
                                  ▼
                            in_progress ───▶ done
                                  │
                                  ├──▶ blocked  (pot agent blocked, or process crash, or CANCEL)
                                  │
                                  └──▶ ready    (re-`ready` after blocked)
```

Transitions:

| From → To | Trigger | Writer |
|---|---|---|
| (none) → inbox | new file created | chat client or human |
| inbox → ready | promotion | chat client (`pot do ready <id>`) or human |
| ready → in_progress | atomic claim | `pot do watch` |
| in_progress → done | `result` event from Claude | `pot do watch` |
| in_progress → blocked | `pot agent blocked`, crash, CANCEL | `pot do watch` |
| blocked → ready | manual restart | human or chat client |
| done → ready | manual re-run | human (rare; typically a new task is preferred) |

## Concurrency rules

- **Single-writer-daemon discipline.** Only one `pot do watch` per vault. Two would race on claim and could over-spawn.
- **Claim is a frontmatter mutation + git commit.** The commit message is `pot: claim <ulid>`. If git's optimistic check fails (because the chat client committed first), `pot` re-reads the file; if `agent_owner` is now set, the task is taken — skip.
- **The chat client never sets `agent_owner`** or `status: in_progress`. It only ever creates files, sets `status: ready`, or writes question answers / plan decisions. This makes the writer split unambiguous.
- **Humans editing tasks in-progress** are advised to set `status: blocked` first, edit, then `status: ready`. The daemon does not enforce this; if it sees a body change mid-run, it logs to `transcript.md` and keeps going.

## Git

The vault is expected to be a git repository. `pot` commits its mutations with messages of the form:

```
pot: claim 01HE...
pot: status=in_progress 01HE...
pot: status=done 01HE...
pot: pot agent finding 01HE... (append)
```

Pushing is not Potentiality's job; the user (or a separate `git push` cron) handles remote sync. This keeps Potentiality offline-tolerant.
