# Prior art — OpenAI Symphony

Authoritative read of `openai/symphony` at the May 2026 head, plus community coverage of how the project is used in practice. This document is condensed from a deeper investigation; cross-references are to source files in the upstream repo.

## What it is

`openai/symphony` ([repo](https://github.com/openai/symphony)) is an Apache 2.0 reference implementation, released April 27, 2026, of a *spec* for orchestrating coding agents. The spec (`SPEC.md`) is the canonical artifact; the Elixir tree under `elixir/` is "prototype software intended for evaluation only" (`elixir/README.md`).

OpenAI's stated guidance: *"Tell your favorite coding agent to build Symphony in a programming language of your choice."* This spec follows that suggestion.

## Architecture

Symphony is a long-running Elixir/OTP escript (`bin/symphony WORKFLOW.md`) that:

1. Polls an issue tracker (Linear in the reference) every `polling.interval_ms` (default 30s).
2. For each open issue, creates an isolated workspace and runs a coding-agent session against it.
3. Reads issue state transitions to decide when to start/stop sessions.
4. Optionally exposes a Phoenix LiveView dashboard at `--port`.

The top-level supervision tree (`elixir/lib/symphony_elixir.ex`):

```
SymphonyElixir.PubSub          (Phoenix.PubSub)
SymphonyElixir.TaskSupervisor  (Task.Supervisor)
SymphonyElixir.WorkflowStore   (hot-reloadable WORKFLOW.md)
SymphonyElixir.Orchestrator    (single GenServer; the brain)
SymphonyElixir.HttpServer      (optional, --port)
SymphonyElixir.StatusDashboard (terminal status)
```

### Key modules

| File | Role |
|---|---|
| `orchestrator.ex` (~1655 lines) | The scheduler. Owns the polling tick, the `running` / `claimed` / `retry_attempts` maps. |
| `agent_runner.ex` | Per-issue lifecycle: workspace create, `before_run` hook, agent session loop up to `max_turns`, `after_run` hook. |
| `codex/app_server.ex` (~1097 lines) | **The Codex client**. Spawns `bash -lc "<codex.command>"` (default `codex app-server`) as an Erlang Port, speaks JSON-RPC 2.0 over stdio. |
| `codex/dynamic_tool.ex` | Registers a client-side `linear_graphql` tool the agent can call back into. |
| `tracker.ex` + `linear/{adapter,client,issue}.ex` | Tracker abstraction (`@behaviour`) + Linear GraphQL implementation. |
| `workspace.ex` | Maps `issue.identifier` → `~/code/workspaces/<safe-id>`; runs hooks; can do SSH if `worker_host` is set. |
| `ssh.ex` | Remote worker execution via `ssh`/`scp`. |
| `config.ex` + `config/schema.ex` | Loads `WORKFLOW.md` YAML frontmatter into typed Ecto embedded schemas (no DB — just the validation library). |
| `prompt_builder.ex` | Renders the WORKFLOW.md body as a Liquid template with `{{ issue.identifier }}` etc. |
| `cli.ex` | Escript entrypoint. |
| `symphony_elixir_web/` | Phoenix LiveView dashboard. |

### Data model

No persistence. State is in the orchestrator GenServer:

```elixir
%State{
  poll_interval_ms, max_concurrent_agents, next_poll_due_at_ms, ...,
  running: %{issue_id => %{pid, ref, identifier, issue, worker_host,
                            session_id, codex_*_tokens, started_at, ...}},
  completed: MapSet.new(),
  claimed:   MapSet.new(),
  retry_attempts: %{issue_id => %{attempt, timer_ref, due_at_ms, ...}},
  codex_totals: ...,
  codex_rate_limits: nil
}
```

Restart recovery is tracker-driven (`SPEC.md` §7.4): on boot, read all issues, drop ones in terminal states, re-claim the rest.

### Issue schema

(`linear/issue.ex` and `SPEC.md` §4.1.1)

```
id, identifier, title, description, priority, state, branch_name, url,
assignee_id, blocked_by, labels, assigned_to_worker, created_at, updated_at
```

### Coordination model

Single-orchestrator (one GenServer is the sole authority for dispatch). Concurrency knobs (`config/schema.ex:130-135`):

- `max_concurrent_agents` (default 10)
- `max_concurrent_agents_by_state` (per-tracker-state caps)
- `worker.max_concurrent_agents_per_host`

Worker scheduling across hosts uses a `least_loaded_worker_host` heuristic (`orchestrator.ex:1001-1008`).

## The Codex contract (concentrated in one file)

`elixir/lib/symphony_elixir/codex/app_server.ex` is the only Codex-coupled file. It is a JSON-RPC 2.0 client over stdio.

### Outbound methods Symphony sends

| Method | Purpose |
|---|---|
| `initialize` | clientInfo + `capabilities.experimentalApi: true` |
| `initialized` | notification |
| `thread/start` | `{approvalPolicy, sandbox, cwd, dynamicTools}` → `{thread: {id}}` |
| `turn/start` | `{threadId, input: [{type: "text", text}], cwd, title, approvalPolicy, sandboxPolicy}` → `{turn: {id}}` |
| JSON-RPC replies | responses to inbound tool calls / approval requests |

### Inbound notifications Symphony handles

| Method | Action |
|---|---|
| `turn/completed` / `turn/failed` / `turn/cancelled` | terminal — record outcome |
| `item/commandExecution/requestApproval`, `execCommandApproval` | auto-approve `{decision: "acceptForSession"}` if configured |
| `applyPatchApproval` | same |
| `item/fileChange/requestApproval` | same |
| `item/tool/call` | dispatch to `DynamicTool.execute/2`; send result back |
| `item/tool/requestUserInput` | auto-answer approvals; otherwise emit non-interactive answer or fail |
| All other `method`-bearing notifications | become orchestrator events (`session_started`, `notification`, ...) |

### Sandbox/approval defaults

`config/schema.ex:162-172`:

- `approval_policy: {"reject": {"sandbox_approval": true, "rules": true, "mcp_elicitations": true}}`
- `thread_sandbox: "workspace-write"`
- `turn_sandbox_policy: workspaceWrite` rooted at the issue workspace

## Public API (optional, behind `--port`)

`lib/symphony_elixir_web/router.ex`:

- `GET /` — LiveView dashboard
- `GET /api/v1/state` — JSON snapshot
- `GET /api/v1/:issue_identifier` — per-issue
- `POST /api/v1/refresh` — force a poll tick

No auth.

## Extension points

- **Tracker** is behind an Elixir `@behaviour` (`tracker.ex`):
  ```
  @callback fetch_candidate_issues / fetch_issues_by_states / fetch_issue_states_by_ids
            / create_comment / update_issue_state
  ```
  Concrete adapters: `Linear.Adapter`, `Tracker.Memory` (tests). Spec §11 is "Linear-compatible" but abstract.

- **Agent backend is NOT abstracted** in the Elixir code — `agent_runner.ex` directly aliases `Codex.AppServer`. Swap is supposed to happen at the `codex.command` shell-config level, *if* the replacement speaks the Codex app-server JSON-RPC dialect.

- **WORKFLOW.md hooks**: `after_create`, `before_run`, `after_run`, `before_remove` — each a shell script.

- **Prompt body**: Liquid template.

- **Client-side dynamic tools**: advertised at `thread/start.params.dynamicTools` (e.g. `linear_graphql`).

## Day-to-day user experience

Drawn from community blogs, HN threads, and OpenAI's own announcement.

The dominant loop is **"file the ticket, walk away, come back to a PR."** A representative anecdote (Towards AI on Medium): "By Sunday night, 14 of those issues had merged pull requests with green CI, 3 were sitting in code review with PRs ready, and 3 had been bounced back to me with a comment from the agent explaining exactly why it couldn't make progress."

User-visible surfaces:

- **Linear board** as the primary control plane (Todo → In Progress → In Review → Done).
- **GitHub PRs** as the output, sometimes including CI status, review feedback, complexity analysis, and walkthrough videos.
- **Phoenix LiveView dashboard** for real-time agent status.
- **Per-issue workspace** like `~/code/symphony-workspaces/MT_123/`.

It is **always-on**, not fire-and-forget. The polling loop and crash-restart behavior are the value.

## Deployment patterns

- Local on a dev machine (sometimes literally a tmux pane).
- Mac mini / personal Linux box (claims ~200 MB RAM for 10 agents).
- Fly.io / managed containers for "always-on with TLS."
- Docker the most common path: `docker run` with env vars.
- Required floor: Elixir 1.17+, Erlang/OTP 27+, **PostgreSQL**, a Linear workspace, an OpenAI key.

## Critiques

Cross-source themes:

| Complaint | Source |
|---|---|
| Heavy token consumption | mindwiredai, multiple HN comments |
| Linear lock-in in v1 | several |
| Spec opacity ("inscrutable agent slop... lists DB fields, mentions a state machine then doesn't describe it") | HN user `exclipy`, 47252045 |
| Requires hermetic tests / CI / clean issues to be useful | opentools.ai |
| Review burden inverts (validation doesn't scale) | opentools.ai |
| Silent drift in code style over time | Rick's Cafe AI |
| Composio: "for solo developers, T3 Code or Agent Orchestrator (with manual spawn) are recommended" | ComposioHQ discussion #526 |

## Why this matters for Potentiality

The Codex coupling is concentrated in **one file** (~1097 lines). Everything outside `codex/` is agent-agnostic. The tracker is already pluggable. The orchestrator/scheduler/workspace/hooks/dashboard are reusable patterns.

But: the *deployment shape* (Postgres, Elixir, Linear, 200 MB RAM, polling daemon) is built for teams. For a solo developer, the prerequisites cost dwarfs the value. The HN/Composio consensus is unambiguous.

Potentiality's design borrows:

- Per-task isolated workspace
- Versioned config (WORKFLOW.md → frontmatter)
- Hooks
- Per-task budget caps
- The idea that the tracker is abstracted (we make it the vault)

Potentiality's design drops:

- Postgres
- Elixir/OTP
- Polling loop as the only trigger (we use fsnotify + CLI invocations)
- Phoenix LiveView dashboard
- SSH workers
- Linear coupling
- Multi-state concurrency caps
- The team-shaped assumptions

See [10-non-goals.md](../10-non-goals.md) for the full list.
