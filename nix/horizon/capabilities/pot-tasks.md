---
id: pot-tasks
description: "Load when the user wants to file or check on long-running autonomous agent work (coding, research, design, review) handled by the Potentiality runner. Also loads on vault-watcher events under tasks/* — new questions awaiting an answer, new plans awaiting a decision, or status transitions to done/blocked."
watch:
  - "tasks/*/questions/[0-9][0-9][0-9].md"
  - "tasks/*/plan.notified"
  - "tasks/*/task.md"
schedule: 1m
---

You delegate long-running work to Potentiality, an autonomous Claude Code
runner that writes results into `tasks/<ULID>/` in the same vault.

## When to file a task

Call `task_new` if the user asks for something that:

- Edits files in a working directory (`kind: code`).
- Requires independent investigation that would consume the orchestrator's
  context unnecessarily (`kind: research`, `kind: design`).
- Reviews artifacts (`kind: review`).

Do NOT use Pot for quick replies, simple lookups, or anything other
tools can satisfy in a single round — every Pot task spawns a separate
agent with its own LLM budget.

Pass the inbound event's `chat_id` to `task_new` so the task is bound to
the chat that requested it. Questions, plan decisions, and final status
updates will route back there.

## File layout the daemon writes

- `tasks/<id>/task.md` — YAML frontmatter (status, kind, agent_owner, …) followed by the user prompt.
- `tasks/<id>/meta.yaml` — session id, cost, current step, plan_decision, and the `telegram.chat_id` you bound at creation time.
- `tasks/<id>/questions/<NNN>.md` — YAML frontmatter (`asked_at`, `urgency: normal|high`, optional `options: [...]`) followed by the question text.
- `tasks/<id>/questions/<NNN>.answer.md` — written by `task_answer`; the agent reads it to unblock.
- `tasks/<id>/plan.md` — raw markdown (no frontmatter). State lives in `meta.yaml#plan_decision` (`pending`, `approved`, `revise`, `rejected`).
- `tasks/<id>/findings.md` — written by `kind: research` / `kind: design` tasks. The deliverable for those kinds.
- `tasks/<id>/deliveries.yaml` — written by **this capability** (not the daemon) to log plan notifications that were actually delivered. Structure:
  ```yaml
  plans:
    - first_line: "<first non-empty line of plan.md at send time>"
      chat_id: "<chat_id>"
      sent_at: "2026-05-14T09:43:17Z"
  ```
  This is the authoritative record of whether a plan was delivered. The file is written **only after** `send_telegram` returns successfully. A missing or empty file means no plan has been delivered yet.
- `tasks/<id>/transcript.md` and `transcript.jsonl` — agent transcripts; useful for `task_tail` debugging but not for user replies.

Never edit these directly. Always use the `task_*` tools.

## Reacting to vault events

The vault-watcher fires on create/modify of paths matching this
capability's `watch` globs. Decide what to do based on the path and
current state:

### `tasks/<id>/questions/<NNN>.md`

1. Read the file. Parse the YAML frontmatter for `urgency` and `options`.
2. Read `tasks/<id>/meta.yaml` for `telegram.chat_id`. If missing, this task wasn't filed from a chat — skip.
3. If `tasks/<id>/questions/<NNN>.notified` exists, skip (already posted).
4. Post the question body via `send_telegram(chat_id, text)`. If `options` is set, list them as numbered choices in the message (Telegram inline keyboards aren't reachable from the bash allowlist; numbered choices the user can reply to are the next best thing).
5. Write an empty marker via `write_file` at `tasks/<id>/questions/<NNN>.notified`.

### `tasks/<id>/plan.notified`

This file is written by `pot agent plan` only after `plan.md` is fully written,
making it the single reliable trigger for plan notifications.

**Before sending, perform an idempotency check using `deliveries.yaml`:**

1. Read `tasks/<id>/meta.yaml#plan_decision`. If it is `approved`, `revise`, or
   `rejected`, the agent has already acted on this plan — stop, do nothing.

2. Read `tasks/<id>/plan.md` verbatim with `read_file`. Extract the first
   non-empty line (the plan's identity key).

3. Read `tasks/<id>/deliveries.yaml` with `read_file`.
   - If the file exists and contains a `plans:` list, check whether any entry's
     `first_line` matches the first non-empty line you extracted in step 2.
   - **Match found → plan already delivered → stop, do nothing.**
   - No match (or file absent/empty) → proceed to send.

   **Do NOT use `plan.notified` itself as an idempotency check.** Its content
   is unreliable: it may be pre-written before a successful send, truncated to
   0 bytes, or re-written by another process. `deliveries.yaml` is the only
   authoritative delivery record.

4. Read `tasks/<id>/meta.yaml` for `telegram.chat_id`. If missing, skip.

5. Post via `send_telegram` with the **verbatim `plan.md` body** (exactly what
   `read_file` returned in step 2 — do NOT compose, draft, paraphrase, or
   summarize), followed by a single line break and the cue:
   "Reply with **approve** / **reject** / a revision instruction."

6. **Only after `send_telegram` returns successfully**, append a delivery record
   to `tasks/<id>/deliveries.yaml`. Use `write_file` to write (or overwrite
   with the updated content):
   ```yaml
   plans:
     - first_line: "<first non-empty line of plan.md>"
       chat_id: "<chat_id>"
       sent_at: "<ISO 8601 timestamp>"
   ```
   If the file already contained earlier entries (from plan revisions), preserve
   them in the list and append the new entry.

   Never write to `deliveries.yaml` before the send succeeds. A write here is
   a commitment that the user received the message.

### `tasks/<id>/task.md`

1. Read frontmatter. If `status` is not `done` or `blocked`, skip — the daemon writes task.md on every status change, including intermediate ones.
2. If `tasks/<id>/status.<status>.notified` exists, skip.
3. Post a one-line status to the bound chat. For `kind: research` / `kind: design`, prepend the first ~20 lines of `tasks/<id>/findings.md` if it exists.
4. Write `tasks/<id>/status.<status>.notified`.

The watcher may fire repeatedly for the same path (initial create, then
status updates). The `.notified` markers make all of the above
idempotent — re-firing is safe.

## Answering "what's the status?" questions

When the user asks about the current state of a task (plan sent, awaiting
approval, etc.), answer **from the files, not from memory**:

- **Was the plan sent?** — Non-empty `tasks/<id>/deliveries.yaml` with at least
  one `plans:` entry whose `chat_id` matches this chat → yes. Absent or empty
  file → no. Never infer delivery from `plan.notified` alone.
- **Is approval pending?** — `meta.yaml#plan_decision: pending` AND
  `deliveries.yaml` has a matching entry → plan sent and awaiting approval.
- **Was the plan revised?** — Multiple entries in `deliveries.yaml#plans` means
  multiple rounds of plan delivery happened.

If you have not read `deliveries.yaml` yet in this turn, read it now before
answering. Stating that a plan was sent when `deliveries.yaml` is absent or
empty is always wrong — that was the failure mode in the 2026-05-14 incident.

## Reacting to user replies

When the inbound event is a Telegram message in a chat that has an
outstanding question or pending plan for some task, route it:

### Question reply

Find the most recent `tasks/<id>/questions/<NNN>.md` where
`meta.yaml#telegram.chat_id` matches this chat and no sibling
`questions/<NNN>.answer.md` exists. Call `task_answer(id, NNN, reply)`.

If the user is selecting from `options` (e.g. they wrote "2"), resolve
the index to the option's text and pass that as the answer.

### Plan reply

If the user's reply targets a task whose `meta.yaml#plan_decision` is
still `pending`, classify the reply text:

- Affirmative (`approve`, `yes`, `ok`, `go ahead`, ✓) → `task_approve(id)`
- Negative (`no`, `cancel`, `reject`, `stop`) → `task_reject(id)`
- Anything substantive otherwise → `task_revise(id, reply)`

After `task_approve`, phrase the confirmation reply according to the
task's `kind` (read from `tasks/<id>/task.md` frontmatter — do not
guess):

- `kind: code` → "The agent will now implement the plan."
- `kind: research` → "The agent will now write up the research as `findings.md`."
- `kind: design` → "The agent will now write the design doc as `findings.md`."
- `kind: review` → "The agent will now write the review as `findings.md`."
- `kind: general` → "The agent will now proceed."

Do not say "implementing" for non-`code` kinds — design/research/review
tasks produce a document (`findings.md`), not a code change.

### Ambiguity

If multiple tasks in this chat have pending state, ask the user to
disambiguate by short title rather than guessing.

## Conventions

- ULIDs are exactly 26 chars in Crockford base32: `[0-9A-HJKMNP-TV-Z]{26}` (no I/L/O/U). Use that regex when extracting from text.
- Question numbers are zero-padded to 3 digits (`001`, `002`, …).
- Files in `tasks/<id>/` are daemon-owned. The only files this capability writes there are the `.notified` markers (its own bookkeeping). Everything else goes through `task_*` tools.
