# 08 — Chat-client integration

Potentiality has no opinion about which chat client you put in front of it. Any program that can do three things can play the role:

1. Watch files in the vault and react to new ones.
2. Execute bash commands like `pot do new` / `pot do answer` etc.
3. Talk to the user over a chat surface — Telegram, Slack, Discord, IRC, Matrix, whatever.

This document specifies the contract from Potentiality's side: what files to watch, what commands to call, what state to track per chat thread. Two concrete chat clients are known to fit cleanly:

- [`purplenoodlesoop/horizon`](https://github.com/purplenoodlesoop/horizon) — a Dart single-binary personal assistant with a vault watcher and a bash-command-templates tool model. The integration is direct: add a handful of allowlist entries and extend the existing vault watcher.
- [`openclaw/openclaw`](https://github.com/openclaw/openclaw) — a multi-channel chat hub (Telegram, Slack, Discord, WhatsApp, iMessage, Matrix, …). The integration is via a skill that does the same three things; one isn't shipped in the OpenClaw skills registry yet but the shape is straightforward.

You can also wire this up with hand-written code, a shell script polling `vault/tasks/`, or a custom Home Assistant automation. Nothing here is bespoke to one project.

## What the chat client needs to do

### 1. Expose tools that call `pot do *`

Whatever the client calls "tools" — Horizon's bash command templates, OpenClaw's skills, a Slack bot's slash commands — register entries that invoke the orchestrator-side verbs in [`04-cli.md`](./04-cli.md). The minimum useful set:

| Tool name (suggested) | Command |
|---|---|
| `task_new` | `pot do new --kind {kind} --title {title} --status ready -- {body}` |
| `tasks_list` | `pot do list --format json [--status …] [--kind …]` |
| `task_show` | `pot do show {id} --format json [--tail N]` |
| `task_tail` | `pot do tail {id} --tail 50` |
| `task_kill` | `pot do kill {id}` |
| `task_answer` | `pot do answer {id} {num} -- {answer}` |
| `task_approve` | `pot do approve {id} [--revise TEXT | --reject]` |

In Horizon's allowlist format (YAML, see [Horizon's docs](https://github.com/purplenoodlesoop/horizon)):

```yaml
- name: task_new
  description: Create a new Potentiality task in the vault.
  parameters:
    kind:  { type: string, description: "code | research | design | review | general" }
    title: { type: string, description: "Short one-line title" }
    body:  { type: string, description: "Task prompt" }
  command: pot do new --kind {{kind}} --title {{title}} --status ready -- {{body}}
```

In OpenClaw's skill format (`SKILL.md` + handler), the shape differs but the underlying invocation is the same shell command.

The chat client's LLM tool-calling loop is what binds "user typed `/task ...`" to "run `pot do new`." Potentiality is unaware of how that binding happens.

### 2. Watch the vault for three patterns

Whatever the client uses to watch files (fsnotify, kqueue, polling), it needs to recognize three glob patterns:

#### Pattern A — new question

Glob: `vault/tasks/*/questions/[0-9][0-9][0-9].md`
Exclude paths matching `*.answer.md`.

On match:
1. Parse YAML frontmatter and body.
2. Look up the bound chat thread (see [Thread binding](#3-thread-binding) below).
3. Post the question body to that thread.
4. If `options:` is present in the question's frontmatter, render the options as inline-keyboard buttons (or whatever the client's UI for multiple-choice looks like).
5. If `urgency: high`, escalate the notification (loud ring, mention, etc.).
6. Remember `(chat-thread, task_id, question_num)` so a later user reply routes back correctly.

#### Pattern B — new plan awaiting decision

Glob: `vault/tasks/*/plan.md`
Condition: `vault/tasks/<id>/meta.yaml#plan_decision` is unset, `null`, or `pending`.

On match:
1. Post `plan.md` to the bound thread.
2. Render `Approve` / `Revise` / `Reject` as buttons or quick-reply options.
3. Remember `(chat-thread, task_id)`.

#### Pattern C — task status change to done / blocked

Glob: `vault/tasks/*/task.md`
Condition: frontmatter `status` is now `done` or `blocked` and wasn't before.

On match:
- Post a one-line status to the bound thread.
- For `kind: research | design`: include a preview of `findings.md`.

### 3. Thread binding

When the chat client creates a task via `task_new`, it should record the binding into `meta.yaml` so subsequent question/plan/status messages reach the same conversation:

```yaml
telegram:
  chat_id: -1001234567890
  thread_id: 42
  message_id: 1001
  user_id: 7654321
```

The field name `telegram` is conventional but not enforced. A Slack-flavored client could write a `slack:` block instead; Potentiality doesn't read this field — it's metadata the chat client owns.

### 4. Route user replies back

When the user sends a message into a bound thread, the client:

- If a question is pending on that thread: write the message to `vault/tasks/<id>/questions/NNN.answer.md`. Button presses get the option text; text replies get the raw text.
- If a plan is pending: write `plan_decision: approved | revise | rejected` and (for revise) `plan_revision: <text>` into `vault/tasks/<id>/meta.yaml`.
- Otherwise: treat as a fresh chat input. May call `task_new` again, or do whatever the client normally does.

## What the chat client does NOT need to know

- Anything about `claude -p`, stream-json, or Claude Code internals.
- The contents of `transcript.jsonl`.
- The lifecycle of the spawned subprocess.
- Cost or budget — that's surfaced through `task_show`.
- Anything about other potential agent backends — `pot` abstracts that away.

## What Potentiality does NOT need to know

- Anything about Telegram, Slack, Discord, channels, users, formatting, or routing.
- Whether the chat client is running.
- Whether the user has one chat client or two.
- That the chat surface even exists.

This is the strongest signal that the design is right: each project ships and is tested without the other.

## Reference clients

### Horizon

Horizon's [vault](https://github.com/purplenoodlesoop/horizon) watcher and bash-command-templates allowlist map directly onto §1 and §2. The integration is additive — drop the entries from §1 into `vault/_horizon/system/allowlist.yaml`, extend Horizon's existing watcher to recognize the three new patterns. Telegram is its native channel.

### OpenClaw

OpenClaw's plugin/skill model handles both halves. A `potentiality` skill would:
- Register the §1 commands as the skill's bash-tool surface.
- Spawn a small Go/TS process (or use OpenClaw's built-in file watcher) to watch the vault for the §2 patterns and forward to whichever channel is bound.
- Use OpenClaw's existing multi-channel router for any of: Telegram, Slack, Discord, WhatsApp, iMessage, Matrix.

Both clients sit on top of the same vault. They are not mutually exclusive — you could run Horizon for Telegram and OpenClaw for Discord against the same vault, and Potentiality wouldn't know.

## Installing the binaries together

Wherever the chat client runs, `pot` must be on its `$PATH`. With Nix and [`core-flake`](https://github.com/purplenoodlesoop/core-flake), install both into the same user profile; or write a wrapper that prepends the right store paths.

## Testing without any chat client

The integration is files. You can drive it from a shell:

```bash
# Simulate "user filed a task"
pot do new --vault ./vault --kind research --status ready -- "Investigate fsnotify on macOS"

# Run the daemon in another terminal
pot do watch --vault ./vault

# When a question file appears:
cat vault/tasks/<id>/questions/001.md

# Answer it:
echo "Option B" > vault/tasks/<id>/questions/001.answer.md

# Watch the transcript
pot do tail <id>
```

No chat client, no LLM tool-calling layer, full HITL coverage. The recommended bring-up path: get the binary running with shell-driven HITL first, then add a chat client.
