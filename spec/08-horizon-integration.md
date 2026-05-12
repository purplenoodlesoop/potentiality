# 08 — Horizon integration

Potentiality and Horizon are *peers around a shared vault*. Neither imports the other; neither calls the other. Integration is a small set of file conventions plus a handful of bash command templates added to Horizon's existing tool allowlist.

This document specifies the Horizon side of the contract. Implementation lives in the Horizon repo.

## What Horizon needs to do

Three additions to Horizon, all minor:

1. **New bash command templates** in `vault/_horizon/system/allowlist.yaml` (or wherever Horizon's tool registry lives) so the LLM running Horizon's chat loop can manage tasks.
2. **New vault-watch patterns** so Horizon notices when Potentiality (via Claude) needs human input.
3. **Telegram-thread-to-task binding** so replies in a specific thread route to the right `questions/NNN.answer.md`.

## Bash command templates

These are entries in Horizon's existing allowlist format. Names are suggestions; the user can rename.

```yaml
- name: task_new
  description: Create a new Potentiality task in the vault.
  parameters:
    kind:
      type: string
      description: One of code, research, design, review, general.
    title:
      type: string
      description: Short one-line title.
    body:
      type: string
      description: The task prompt — what the agent should do.
    repo:
      type: string
      description: Optional. Working directory for the spawn. Defaults to the vault root.
  command: |
    pot do new --kind {{kind}} --title {{title}} --status ready
      {{#repo}}--repo {{repo}}{{/repo}}
      -- {{body}}

- name: tasks_list
  description: List Potentiality tasks (filterable).
  parameters:
    status: { type: string, description: "Optional status filter." }
    kind:   { type: string, description: "Optional kind filter." }
    since:  { type: string, description: "Optional duration filter, e.g. 24h." }
  command: |
    pot do list --format json
      {{#status}}--status {{status}}{{/status}}
      {{#kind}}--kind {{kind}}{{/kind}}
      {{#since}}--since {{since}}{{/since}}

- name: task_show
  description: Show details of one Potentiality task.
  parameters:
    id: { type: string }
    tail: { type: integer, description: "Optional transcript tail size." }
  command: |
    pot do show {{id}} --format json
      {{#tail}}--tail {{tail}}{{/tail}}

- name: task_tail
  description: Tail a running task's transcript (one snapshot).
  parameters:
    id: { type: string }
  command: pot do tail {{id}} --tail 50

- name: task_kill
  description: Cancel a running Potentiality task.
  parameters:
    id: { type: string }
  command: pot do kill {{id}}

- name: task_answer
  description: Answer a pending question from a task.
  parameters:
    id: { type: string }
    num: { type: integer }
    answer: { type: string }
  command: pot do answer {{id}} {{num}} -- {{answer}}

- name: task_approve
  description: Approve, revise, or reject a pending plan.
  parameters:
    id: { type: string }
    decision: { type: string, description: "approved | revise | rejected" }
    revision: { type: string, description: "Revision text when decision=revise." }
  command: |
    {{#decision=approved}}pot do approve {{id}}{{/decision=approved}}
    {{#decision=revise}}pot do approve {{id}} --revise {{revision}}{{/decision=revise}}
    {{#decision=rejected}}pot do approve {{id}} --reject{{/decision=rejected}}
```

These are the only `pot`-related capabilities Horizon's chat LLM needs. Everything else (question delivery, plan delivery, answer routing) happens in Horizon's *vault watcher*, not in its LLM tool loop.

## Vault watcher additions

Horizon already watches the vault for capability and config changes. Extend the watcher to also handle these patterns:

### Pattern 1 — new question

Glob: `vault/tasks/*/questions/[0-9][0-9][0-9].md`
Excludes: paths matching `*.answer.md`.

On a new file:

1. Parse YAML frontmatter and body.
2. Read `vault/tasks/<id>/meta.yaml`. If `telegram.chat_id` is set, post there. Otherwise fall back to Horizon's default channel for the configured user.
3. Send message:
   - Body of the question file as the text.
   - If `options:` present in frontmatter: inline keyboard, one button per option. Callback data: `pot:ans:<id>:<num>:<option-index>`.
   - If `urgency: high`: do not silence the notification.
4. Track in Horizon's in-memory state: `pending_questions[(chat_id, thread_id)] = (task_id, question_num)`.

### Pattern 2 — new plan awaiting decision

Glob: `vault/tasks/*/plan.md`
Condition: `vault/tasks/<id>/meta.yaml#plan_decision` is unset, `null`, or `pending`.

On detection:

1. Post `plan.md` content to the bound thread.
2. Inline keyboard: `Approve` / `Revise` / `Reject`. Callback data: `pot:plan:<id>:<decision>`.
3. Track: `pending_plans[(chat_id, thread_id)] = task_id`.

### Pattern 3 — task done / blocked

Glob: `vault/tasks/*/task.md`
Condition: frontmatter `status` changed to `done` or `blocked`.

On detection:

1. Post a short status line to the bound thread:
   - `done`: "✓ Task `<title>` done. ($X cost)"
   - `blocked`: "✗ Task `<title>` blocked: <reason>"
2. If `kind: research|design` and `findings.md` exists: include first 500 chars as preview, plus a deep-link button to fetch the rest (`/task_show <id>`).

## Telegram thread binding

When Horizon creates a task via `task_new`, it writes the binding into `meta.yaml`:

```yaml
telegram:
  chat_id: -1001234567890
  thread_id: 42
  message_id: 1001         # the original /task_new message, for context
  user_id: 7654321
```

Subsequent question/plan/status messages target the same thread. If the chat is a 1:1 DM (`thread_id` absent), messages go to the chat directly.

## Routing user replies back

When the user sends a message to Horizon (DM or thread), Horizon's existing event handler runs. Augmentation:

1. Identify the chat thread.
2. Look up `pending_questions[(chat_id, thread_id)]` and `pending_plans[(chat_id, thread_id)]`.
3. If a question is pending:
   - Button press: write `vault/tasks/<id>/questions/NNN.answer.md` with the option text.
   - Text reply: write the same file with the full reply text.
   - Clear the pending entry.
4. If a plan is pending:
   - `Approve` button: write `plan_decision: approved` + `plan_decided_at` into `meta.yaml`.
   - `Revise` button: prompt user in-thread for revision text; on reply, write `plan_decision: revise` and `plan_revision: <text>`.
   - `Reject` button: write `plan_decision: rejected`.
5. If neither is pending: fall through to Horizon's normal chat loop (treat as a new user message, may invoke `task_new` etc.).

## Allowlisting `pot` itself

Horizon's tools execute as `bash -c "<rendered template>"`. The `pot` binary must be on `$PATH` when Horizon spawns these commands. With Nix and `core-flake`, install both Horizon and Potentiality into the same user profile, or write a wrapper script that prepends the right store paths.

## What Horizon does NOT need to know

- Anything about `claude -p`, stream-json, or Claude Code internals.
- The contents of `transcript.jsonl`.
- The lifecycle of the spawned subprocess.
- Cost or budget — that's surfaced through `task_show`.
- Anything about other potential agent backends — `pot` abstracts that away.

## What Potentiality does NOT need to know

- Anything about Telegram, channels, users, message formatting, or routing.
- Whether Horizon is running.
- Horizon's user allowlist, system prompts, capabilities, voice transcription, etc.
- That the chat surface even exists.

This is the strongest signal that the design is right: each project can ship and be tested without the other.

## Testing the integration without Telegram

Because the integration is purely files, you can simulate Horizon by hand:

```bash
# create a task as if Horizon did
pot do new --kind research --title "Test" --status ready -- "Investigate fsnotify on macOS"

# run pot do watch in another terminal
pot do watch ./vault

# when a question appears, answer it manually
cat vault/tasks/<id>/questions/001.md
echo "Option B" > vault/tasks/<id>/questions/001.answer.md

# tail the transcript
pot do tail <id> --follow
```

No Telegram, no Horizon, full HITL coverage. Useful for CI and for the first few hours of bring-up before Horizon is wired in.
