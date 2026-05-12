# 05 — Human-in-the-loop

HITL in Potentiality is a thin layer over the file system. There is no RPC, no MCP, no HTTP. There are five interactions:

1. **Question** — Claude asks the user something and blocks.
2. **Answer** — User replies; Claude unblocks.
3. **Plan approval** — Claude proposes a plan; user approves / revises / rejects.
4. **Redirect** (v2) — User interrupts a running task with new instructions.
5. **Cancel** — User stops a running task.

All five are mediated by files in the task directory. The chat client (Horizon, OpenClaw, or anything that can watch and write the vault — see [08-chat-client-integration.md](./08-chat-client-integration.md)) plays the bridge role, but is replaceable.

## Question / answer

### Claude side

Claude calls `pot agent ask`. In the system prompt (set by `pot`), Claude is told:

> When you need a human decision that you cannot make yourself, run:
>
> ```
> pot agent ask "<question>" [--options "a,b,c"]
> ```
>
> The command blocks until a human responds and prints the answer to stdout. Prefer offering 2–4 concrete options when the choice is bounded; use a free-form question only when the answer space is open.

`pot agent ask` does:

1. Read `$POTENTIALITY_TASK_DIR`. Error if unset.
2. Find next free `NNN` in `questions/`.
3. Write `questions/NNN.md` with YAML frontmatter (`asked_at`, `urgency`, `options`) and body = the question.
4. Open an inotify (or kqueue on macOS) watch on `questions/` filtered to `NNN.answer.md`.
5. Also watch `CANCEL` in the task dir.
6. Block on STM `TMVar` until either fires.
7. If answer file: read it, trim whitespace, print to stdout, exit 0.
8. If CANCEL: exit 130.
9. If `--timeout SECONDS` was set and elapsed: write a stub `NNN.answer.md` containing `(timeout)`, exit 124.

### Chat-client side

The chat client watches the vault for new files matching `tasks/*/questions/[0-9][0-9][0-9].md`. When one appears:

1. Parse the YAML frontmatter and body.
2. Look up the chat-binding block in `vault/tasks/<id>/meta.yaml` (e.g. `telegram.chat_id` + `thread_id`, or `slack.channel` + `thread_ts`, etc.).
3. Post to that thread:
   - If `options:` set: send the body text with inline buttons / quick replies, one per option.
   - If no `options:`: send the body text and instruct the user "reply in thread to answer."
4. On button press: write `questions/NNN.answer.md` with the option text.
5. On in-thread reply when a question is pending: write `questions/NNN.answer.md` with the reply text.

If `urgency: high`, the client SHOULD additionally escalate the notification (loud ring, mention, etc.).

### Answer file format

```markdown
CLI
```

For options-based answers: one line, the option text exactly as it appeared in `options:`. For free-form: the full user reply, no formatting changes.

### Multiple pending questions

A task SHOULD have at most one pending question at a time (Claude blocks on `pot agent ask`, so it can't ask another). But if a human manually creates a question file (via `pot do answer` is for answers; a human-authored question would happen during `pot do show` workflows), the chat client resolves them in numeric order.

## Plan approval

Used when `mode: delegate`. The agent's job is to think first, propose, then execute autonomously. The user gates the transition.

### Claude side

```
pot agent plan "<markdown>"
```

Behavior:

1. Write `plan.md` (overwrite). Body is the agent's plan in free-form Markdown.
2. Clear `meta.yaml#plan_decision` (or set to `pending`).
3. Watch `meta.yaml` for `plan_decision` to become `approved` / `revise` / `rejected`.
4. Also watch CANCEL.
5. Block.
6. On approved: print `approved\n`, exit 0.
7. On revise: print `revise: <plan_revision-text>\n`, exit 0. Claude is expected to read the revision and re-call `pot agent plan` with a new plan.
8. On rejected: print `rejected\n`, exit 1. Claude is expected to call `pot agent blocked` or exit.

### Chat-client side

When `plan.md` is created and `meta.yaml#plan_decision` is unset / `pending`:

1. Post `plan.md` to the bound chat thread with three buttons / quick replies: `Approve` / `Revise` / `Reject`.
2. On `Approve`: write `plan_decision: approved` + `plan_decided_at` into `meta.yaml`.
3. On `Revise`: prompt the user in-thread for revision text, then write `plan_decision: revise` and `plan_revision: <text>`.
4. On `Reject`: write `plan_decision: rejected`.

## Redirect (v2)

Not implemented in v1. Reserved design:

User types into a bound thread when no question/plan is pending. The chat client writes `vault/tasks/<id>/inbox/<iso-ts>.md`. `pot do watch` watches each in-progress task's `inbox/`; on new file, it injects the content into the running `claude -p`'s stdin as a user message via `--input-format=stream-json`.

The stream-json input shape for a user interjection (per Claude Code docs):

```json
{"type":"user","message":{"role":"user","content":"<inbox file content>"}}
```

Followed by a newline. Claude treats this as the next user turn.

v1 alternative: `pot do kill <id>` and create a new task with a refined prompt. The cost is small because `transcript.md` and `findings.md` are still on disk.

## Cancel

User: `pot do kill <id>` (or the chat client shells out to it on a `/task_kill` command). Behavior: touch `vault/tasks/<id>/CANCEL`. The owning `pot do watch` sees the file (it watches each in-progress task dir for `CANCEL`), sends SIGTERM to its claude child, waits 5 seconds, SIGKILL if still alive, then writes `status: blocked, reason: cancelled` and removes `CANCEL`.

Pending `pot agent ask` calls also see the CANCEL file and exit 130, freeing any blocked agent-side processes.

## Why this design

- **No new protocol.** Files. inotify. Markdown.
- **Crash-safe.** A question file or plan file on disk survives any process crash on either side. On restart, watchers re-fire.
- **Mobile-native.** Obsidian, Working Copy, the GitHub mobile app, or `cat` over SSH all read the same files.
- **Composable.** Want to bridge a different chat tool (Slack, Matrix, IRC)? Implement the same watch-and-write pattern. No chat client is load-bearing; the vault is.
- **Symmetric with the chat clients we know about.** Horizon's own tools are bash command templates over file IPC; OpenClaw's skills are bash invocations too. Potentiality's agent-side tools are bash subcommands over file IPC. Same mental model up and down the stack.
