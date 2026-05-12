# Prior art — OpenClaw + Symphony ecosystem

OpenClaw is a multi-channel personal-AI hub (Telegram, Slack, Discord, WhatsApp, iMessage, Matrix, ...). It is not itself a Symphony competitor; it's the chat substrate. Several projects sit between it and coding-agent orchestration. They are the most directly relevant prior art for Potentiality's HITL design.

## `openclaw/caclawphony` — OpenClaw's internal Symphony pipeline

[Repo.](https://github.com/openclaw/caclawphony) Self-described:

> "Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage work instead of supervising coding agents."

It is the *automation tool for the OpenClaw repository itself*: an "automated PR triage, review, and merge pipeline" that uses Symphony for orchestration and Linear for state.

### Architecture

| Layer | Role |
|---|---|
| Symphony (framework) | Polling, state management, agent dispatch |
| Caclawphony (domain wrapper) | PR-specific operations, GitHub + Linear API integration |
| Codex agents | Pipeline workers |
| Linear issues | State machine (Triage → Todo → Review → Prepare → Done) |

### Flow

```
gh PR opened
   ▼
mix caclawphony.review <PR#>          (manual or via webhook)
   ▼
Linear issue created in Triage state
   ▼
Symphony polling tick (30s)
   ▼
Codex agent dispatched for triage
   ▼
Issue → Todo  (or stays in Triage if maintainer rejects)
   ▼
Codex agent → Review
   ▼
Issue → Review Complete (with findings)
   ▼
Maintainer chooses: Prepare / Request Changes / Closure
   ▼
... Prepare ... Prepare Complete ...
   ▼
Maintainer verifies → Merge
```

### HITL via approval gates

The hallmark feature: **agents are explicitly forbidden from acting outside authorized states.** Rule (paraphrased): "agents never comment on GitHub without being in an authorized state." Human approval transitions the state, which unlocks the next agent action. Three named human gates:

- **Todo gate** — maintainer reviews triage enrichment before full review proceeds
- **Review Complete gate** — maintainer routes to Prepare / Request Changes / Closure
- **Prepare Complete gate** — human verifies agent modifications before merge

### What we take

- **Approval gates are first-class state transitions, not implicit "the human will get to it eventually."**
- **The agent's privileges are bounded by the state.** State = capability.

### What we leave

- Linear-driven (we use the vault).
- PR-shaped (we handle research/design/review too, not just code).
- No chat integration — purely state-driven.

## `goldmar/openclaw-code-agent` — the directly relevant one

[Repo.](https://github.com/goldmar/openclaw-code-agent) Self-described as: runs Claude Code and Codex as managed background coding sessions from OpenClaw chat, adding plan approval, session lifecycle, wake routing, worktree isolation, merge/PR follow-through, and explicit goal loops.

This is the closest match to what Potentiality does. The README's protocol is the model to learn from.

### Launch

`agent_launch` is the OpenClaw-side tool the chat LLM invokes:

```
agent_launch {
  harness: "claude-code" | "codex",
  workdir: string,
  worktree_strategy: ...
}
```

The plugin executes the agent backend in an isolated subprocess, with output buffered and routable back to the originating chat thread.

### Session lifecycle states

```
active                — running
pending decision      — waiting for human input
pr_open               — PR opened, awaiting review
merged                — PR merged
released              — change landed via rebase/squash
dismissed             — cancelled / abandoned
no_change             — agent decided nothing to do
```

### Plan approval

> "The plugin receives a structured plan artifact, blocks implementation until approval, and continues the same session after the plan is approved."

User responds with `Approve`, `Revise`, or `Reject` in the same thread. Revisions accumulate; "the newest plan is the actionable one." All in one chat conversation, no new sessions.

Tools: `agent_request_plan_approval`, `agent_send_plan_offer` (sends a `Start Plan / Dismiss`-buttoned offer message).

### Modes

- `delegate` (default) — receive plan → block → continue same session after approval. Autonomous once approved.
- `ask` — state-dependent buttons appear at each step. More clicks, more control.

### Wake routing

> "Chat-launched sessions route updates back to their originating chat thread."

If a session has no origin thread (e.g. launched via CLI), the plugin falls back to `fallbackChannel` or `agentChannels` configuration.

### Worktree isolation

> "The agent edits files in the managed worktree so the main checkout is not touched during implementation."

Sandbox persists across decisions. After review, delegated follow-through merges back unless conflicts or policy require escalation.

### Merge / PR follow-through

In `ask` mode: state-dependent buttons appear (new branch ⇒ Merge / Open PR / Later / Discard; existing PR ⇒ View PR / Sync PR).

In `delegate` mode: orchestrator reviews completed worktree, attempts clean merge automatically.

### Goal loops

`goal_launch` for verifier-driven repair (Ralph-style):

> "fix the failing auth flow and keep running pnpm test until it passes" or "consider it complete when the output says DONE."

### Mid-task interaction

> "Follow-ups, approvals, revisions, interrupts, and redirects all continue the existing session instead of launching a duplicate."

Mechanics: plain-text in the same thread, or `/agent_respond` for explicit "Reply, redirect, approve a plan, or escalate permissions."

### State

`~/.openclaw/openclaw.json` for config; session data via `agent_sessions` and `agent_output` tools, implying a managed backend store rather than user-readable filesystem.

### What we take

- **Chat thread = session = task as the 1:1 binding.** Direct inspiration.
- **Plan approval is a gate, not a start signal** — agent proposes, human approves/revises/rejects, then proceeds.
- **`ask` vs `delegate` mode knob** — same architecture, different default autonomy.
- **Goal loops** — verifier-driven repair as a primitive (future v2 for Potentiality).
- **Lifecycle states** — `active`, `pending decision`, `done`, `blocked` map cleanly.
- **Wake routing** as a concept — the agent never knows about the channel; the channel layer routes.

### What we leave

- **State lives in a managed backend store.** We put it in the vault as files. Same idea, different substrate.
- **MCP / structured-tool protocol.** We use bash subcommands.
- **OpenClaw plugin architecture.** We use Horizon directly.

## ACP — Agent Client Protocol

[Reference write-up.](https://www.openclawplaybook.ai/blog/openclaw-acp-agents-coding-workspace/)

Emerging standard for "chat thread as coding workspace." Two modes:

- `run` — one-shot execution for isolated tasks
- `session` — persistent, thread-bound, multi-turn

Thread binding: `--thread auto|here|off` anchors a workspace to a specific chat thread. Quote:

> "come back hours later, send a follow-up message in that thread, and Claude Code picks right up where it left off — with full context."

Steering: `/acp steer` for mid-task instruction corrections without stopping execution.

Streaming: `streamTo: "parent"` for live progress visibility without polling.

### What we take

- The `run` / `session` distinction — for Potentiality, `pot do run` is one-shot, `pot do watch` is the session-spawner.
- Thread binding (stored in `meta.yaml#telegram`).
- The idea that mid-task steering is `same thread, just type` — even though v1 punts on the redirect channel.

### What we leave

- The ACP spec itself isn't a stable standard yet. We don't aim for conformance. If it stabilizes and the user wants interop, the file-based model can serve as a backend behind an ACP shim without changing the core.

## `Enderfga/claw-orchestrator`

[Repo.](https://github.com/Enderfga/claw-orchestrator)

Self-described: "Run Claude Code, Codex, Gemini, Cursor Agent and custom coding CLIs as one unified runtime for claw-style agent systems. Runs standalone, with first-class OpenClaw plugin support."

The pluggable-agent-backend project. Implements an abstraction that openai/symphony does not (Symphony's `agent_runner.ex` is Codex-only). Validates the idea that a clean typeclass over coding-agent CLIs is implementable.

### What we take

- An `AgentBackend` typeclass should exist in Potentiality's source so Codex / Aider / Gemini / Cursor are addable without touching the orchestrator.

### What we leave

- We do not implement those backends in v1. Claude Code only. Add when there's a reason.

## `openclaw/skills` — `codex-orchestration` SKILL

[Path.](https://github.com/openclaw/skills/blob/main/skills/shanelindsay/codex-orchestration/SKILL.md) (URL 404'd on direct fetch during research; cited indirectly via Composio summaries.)

A community OpenClaw skill that lets the chat-LLM act as a Codex orchestrator: analyzes requirements, decomposes into tracks, dispatches Codex workers in parallel, synthesizes results on the main thread.

### What we take

- The pattern of *orchestrator-as-skill* validates that a thin chat-LLM layer can drive a coding-agent runtime through declarative tools — which is exactly what Horizon's bash command templates do for Potentiality.

## Cross-project convergence

Five conventions appear in all three relevant projects (caclawphony, openclaw-code-agent, ACP). Potentiality adopts all five:

1. **Chat thread = session = task.** 1:1 binding.
2. **Plan approval is a gate**, not a one-time start signal.
3. **Redirect / steer mid-flight by typing in-thread**, not by separate commands.
4. **Mode knob: `ask` vs `delegate`.**
5. **`goal_launch`-style "keep going until verified"** is a distinct primitive from one-shot tasks. (Reserved for v2.)

## What's missing in all of them (and that Potentiality fixes)

- **The state is in a managed backend, not user-readable files.** openclaw-code-agent talks about `agent_sessions` and `agent_output` tools — the user can't `cat` or `grep` the session state. Potentiality keeps everything in the vault.
- **MCP/protocol surface.** All three rely on MCP or structured tool protocols. We don't.
- **Tracker lock-in (Linear for caclawphony).** We use the vault.
- **Code-task bias.** openclaw-code-agent is good for coding; less obviously useful for research/design/review. Potentiality's kind taxonomy makes those first-class.
