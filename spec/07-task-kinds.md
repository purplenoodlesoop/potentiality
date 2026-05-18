# 07 — Task kinds

Five built-in kinds. Each is a tuple of (default tool set, default mode, default permission mode, system-prompt addendum, output convention).

Kinds are convention, not enforcement: the user can override `allowed_tools`, `mode`, `permission_mode`, and `tools` in frontmatter. The kind picks the defaults.

## `code` — modify a repository

| Property | Default |
|---|---|
| `mode` | `delegate` |
| `permission_mode` | `acceptEdits` |
| `allowed_tools` | `Bash(pot agent *), Bash, Read, Edit, Write, Grep, Glob` |
| Output convention | Files in the repo; ideally a committed branch or PR |

**System prompt addendum:**

> This is a `code` task. You are operating in a working repository at `$PWD`.
>
> Before making changes, call `pot agent plan` with a short Markdown plan
> describing what you will change and why. After the user approves, execute.
>
> When done, summarize what changed in `pot agent done --message "..."`. Do not
> push to a remote. Do not commit unless the user asked you to; otherwise leave
> changes staged.

**Lifecycle:** plan → approve → edit → done. The user inspects the working tree (or `git diff`) afterwards.

**Optional v2 features:** auto-create a `git worktree` per task to avoid contaminating the user's main checkout. Auto-open a PR if `auto_pr: true` is set.

## `research` — investigate something and report

| Property | Default |
|---|---|
| `mode` | `ask` |
| `permission_mode` | `default` |
| `allowed_tools` | `Bash(pot agent *), Read, WebSearch, WebFetch, Task` |
| Output convention | `findings.md` |

**System prompt addendum:**

> This is a `research` task. Your goal is to investigate the question in the
> task body and produce a written synthesis in `findings.md`.
>
> Use the `Task` tool to spawn parallel subagents for independent threads of
> investigation. Use `WebSearch` and `WebFetch` to gather sources. Cite URLs in
> your findings.
>
> Use `pot agent ask --options "..."` to surface forks in the road (e.g. "should
> I prioritize X or Y?"). Be willing to ask questions early — your work is for
> a human who will redirect you if you go off course.
>
> Use `pot agent finding "## Section..."` repeatedly to build `findings.md`
> incrementally. Do not write to `findings.md` directly with the Write tool.

**Lifecycle:** prompt → optional ask → research (possibly subagents) → ask again as needed → write findings → done. This is the kind that mirrors the work the human user did with Claude to design this very spec.

## `design` — produce a plan / spec / architecture document

| Property | Default |
|---|---|
| `mode` | `delegate` |
| `permission_mode` | `default` |
| `allowed_tools` | `Bash(pot agent *), Read, WebSearch, WebFetch, Task, Write` |
| Output convention | `plan.md` (approved) + `findings.md` (the design) |

**System prompt addendum:**

> This is a `design` task. Your goal is to produce a design document or
> architectural plan.
>
> First, do enough research to be grounded — `WebSearch`, `WebFetch`, `Task`
> subagents, `Read` of any provided code paths. Then call `pot agent plan`
> with your approach and wait for approval.
>
> After approval, write the design as `findings.md` via repeated `pot agent
> finding` calls. Cite sources. Mark sections clearly with `##` headings.

**Lifecycle:** investigate → plan → approve → write findings → done.

`design` differs from `research` in that the user expects a deliverable in a known shape (a design doc), not just a synthesis. Plan gate forces alignment before writing.

## `review` — read-only inspection

| Property | Default |
|---|---|
| `mode` | `ask` |
| `permission_mode` | `default` |
| `allowed_tools` | `Bash(pot agent *), Read, Grep, Glob` |
| Output convention | `findings.md` (the review) |

**System prompt addendum:**

> This is a `review` task. You may read files and grep but MUST NOT modify
> anything in the repository.
>
> Produce your review as `findings.md` via `pot agent finding` calls. Use
> `pot agent ask` to clarify intent if the task body is ambiguous.

**Lifecycle:** read → ask if needed → write review → done.

Good for "review this PR / diff / module," "explain this code," "check this for security issues" workflows that don't change the codebase.

## `general` — anything else

| Property | Default |
|---|---|
| `mode` | `ask` |
| `permission_mode` | `default` |
| `allowed_tools` | `Bash(pot agent *), Read` |
| Output convention | `transcript.md` (no specific output file) |

**System prompt addendum:**

> This is a `general` task. The task body describes what the user wants. You
> have minimal tools by default; use `pot agent ask` liberally to clarify and
> propose. If the task body asks for capabilities beyond your current toolset,
> explain that and call `pot agent blocked --reason "need tools: ..."`.

**Lifecycle:** ask → discuss → done or blocked.

For everything that doesn't fit the four specific kinds. Defaults are minimal and conservative on purpose; expand via frontmatter overrides when needed.

## Choosing a kind

| If the task involves... | Kind |
|---|---|
| Editing files in a repo, running tests, committing | `code` |
| Producing a written investigation with citations | `research` |
| Producing a design doc, spec, or architectural plan | `design` |
| Reading a repo / PR / file and reporting | `review` |
| Anything else | `general` |

`general` is the escape hatch and should be rare; if the same `general` prompt shape appears repeatedly, consider adding a new kind.

## Adding a new kind

New kinds live in the source (`src/Potentiality/Kind/<Name>.hs`) and define:

```haskell
data KindSpec = KindSpec
  { kindName        :: Text          -- "code", "research", ...
  , kindMode        :: Mode          -- Ask | Delegate
  , kindPermMode    :: PermissionMode
  , kindTools       :: [Text]        -- raw --allowedTools entries
  , kindPromptAdd   :: Text          -- appended to system prompt
  , kindOutputFile  :: Maybe Text    -- "findings.md" | Nothing
  }
```

Kinds are not pluggable at runtime in v1; adding one is a code change. Worth noting: this is a deliberate constraint to keep the surface small.

## Per-kind contract files (operator-defined)

Each kind's source-defined `kindPromptAdd` is the **mechanism-level** prose that ships with `pot` and applies to every task of that kind, regardless of who deploys the daemon. Operators can also add **deployment-level** prose by dropping a markdown file at:

```
<vault>/_potentiality/kinds/<kind>.md
```

When present, that file's contents are appended to the spawned agent's system prompt immediately after the kind's source-defined preamble and the `Mode:` line. Opt-in: a missing file means no extra prose, and behavior is identical to pre-#10 builds.

Typical uses:

- `kind: code` → "before calling `pot agent done`, run the repo's verification command (e.g. `nix build`, `pytest`) and report the result inline."
- `kind: research` → "before declaring done, cross-reference the findings against the relevant capability or knowledge file and link both ways."
- `kind: design` → "every proposal must include an `## Alternatives considered` section."

The file is read **fresh per spawn** — edits propagate on the next task without restarting the daemon, mirroring how capabilities work in Horizon.

## Pre-`done` verify hook (per-task)

Tasks can declare a shell command in frontmatter:

```yaml
---
kind: code
title: Implement X
verify: nix build .#default
---
```

When set, `pot agent done` runs the command via `bash -c <verify>` before accepting the transition. Non-zero exit refuses the transition — the task stays `in_progress`, the verify output is appended to `transcript.md` under a `## verify (exit=N)` header, and `pot agent done` exits with code 2 so the spawned agent can read the failure and fix-and-retry without operator intervention.

A successful verify proceeds with the normal done sequence (sets `finished_at`, overwrites `current_step`, etc.).

The verify hook is **opt-in per task**. A `kind: code` task whose frontmatter has no `verify:` field behaves exactly as today.

Together, the kind contract file and the verify hook implement the two-layer policy described in issue #10: the contract tells the agent **what** to check, the verify hook enforces that it **was** checked.
