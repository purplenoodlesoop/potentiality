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
