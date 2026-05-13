-- | Per-kind defaults: allowed tool set, default mode and permission
-- mode, and the system-prompt addendum 'Potentiality.ClaudeCode' injects
-- via @--append-system-prompt@. Mirrors @spec\/07-task-kinds.md@.
module Potentiality.Kind
  ( KindSpec (..)
  , kindSpec
  , basePromptPreamble
  ) where

import Data.Text (Text)
import Potentiality.Task (Mode (..), PermissionMode (..), TaskKind (..))

data KindSpec = KindSpec
  { ksTools :: [Text]
  , ksDefaultMode :: Mode
  , ksDefaultPermission :: PermissionMode
  , ksPromptAddendum :: Text
  }

-- | Shared preamble prepended to every kind's addendum. Tells the agent
-- what @pot@ subcommands it has and how to use them.
basePromptPreamble :: Text
basePromptPreamble =
  "You are running inside the Potentiality orchestrator. Your task is\n\
  \described in the user message. You have access to a `pot` CLI in your\n\
  \PATH which you invoke through the Bash tool to interact with the\n\
  \orchestrator and the human on the other side.\n\
  \\n\
  \Tools:\n\
  \  pot agent ask \"<question>\" [--options \"a,b,c\"]\n\
  \      Block until a human responds; print the answer to stdout.\n\
  \      Use when you need a human decision you cannot make yourself.\n\
  \\n\
  \  pot agent status \"<one-line>\"\n\
  \      Tell the user what you are currently doing. Fire-and-forget.\n\
  \\n\
  \  pot agent note \"<text>\"\n\
  \      Add a note to the transcript that the user can read later.\n\
  \\n\
  \  pot agent finding \"<markdown>\"\n\
  \      (research/design only) Append synthesized findings to the\n\
  \      output document.\n\
  \\n\
  \  pot agent plan \"<markdown>\"\n\
  \      (delegate mode only) Propose a plan; block until\n\
  \      approved/revised/rejected.\n\
  \\n\
  \  pot agent done [--message \"<text>\"]\n\
  \      Mark the task complete.\n\
  \\n\
  \  pot agent blocked --reason \"<text>\"\n\
  \      Mark the task blocked; explain what the user must do.\n\
  \\n\
  \Rules:\n\
  \  - Prefer `pot agent ask` with `--options` over free-form questions\n\
  \    when the answer space is bounded (2-4 options).\n\
  \  - Call `pot agent status` whenever you start a long step.\n\
  \  - Never call `pot agent finding` for `kind: code`. Use Edit/Write to\n\
  \    modify the repo instead.\n\
  \  - Never speculate about Telegram, channels, users by name, or\n\
  \    message formatting; `pot agent ask` returns a plain string answer.\n\
  \  - When you use `pot agent ask`, call it SYNCHRONOUSLY. Do NOT pass\n\
  \    `run_in_background: true` and do NOT call ScheduleWakeup. The tool\n\
  \    blocks until the human answers — just wait for it to return.\n\
  \  - Never use `run_in_background: true` for any `pot agent *` command.\n"

kindSpec :: TaskKind -> KindSpec
kindSpec = \case
  Code ->
    KindSpec
      { ksTools = ["Bash(pot agent *)", "Bash", "Read", "Edit", "Write", "Grep", "Glob"]
      , ksDefaultMode = Delegate
      , ksDefaultPermission = PMBypassPermissions
      , ksPromptAddendum =
          "This is a `code` task. You are operating in a working\n\
          \repository at $PWD.\n\
          \\n\
          \Before making changes, call `pot agent plan` with a short\n\
          \Markdown plan describing what you will change and why. After\n\
          \the user approves, execute.\n\
          \\n\
          \When done, summarize what changed in `pot agent done --message\n\
          \\"...\"`. Do not push to a remote. Do not commit unless the\n\
          \user asked you to; otherwise leave changes staged.\n"
      }
  Research ->
    KindSpec
      { ksTools = ["Bash(pot agent *)", "Read", "WebSearch", "WebFetch", "Task"]
      , ksDefaultMode = Ask
      , ksDefaultPermission = PMBypassPermissions
      , ksPromptAddendum =
          "This is a `research` task. Your goal is to investigate the\n\
          \question in the task body and produce a written synthesis in\n\
          \`findings.md`.\n\
          \\n\
          \Use the `Task` tool to spawn parallel subagents for\n\
          \independent threads of investigation. Use `WebSearch` and\n\
          \`WebFetch` to gather sources. Cite URLs in your findings.\n\
          \\n\
          \Use `pot agent ask --options \"...\"` to surface forks in the\n\
          \road. Be willing to ask early.\n\
          \\n\
          \Use `pot agent finding \"## Section...\"` repeatedly to build\n\
          \`findings.md`. Do not write to `findings.md` directly.\n"
      }
  Design ->
    KindSpec
      { ksTools = ["Bash(pot agent *)", "Read", "WebSearch", "WebFetch", "Task", "Write"]
      , ksDefaultMode = Delegate
      , ksDefaultPermission = PMBypassPermissions
      , ksPromptAddendum =
          "This is a `design` task. Your goal is to produce a design\n\
          \document or architectural plan.\n\
          \\n\
          \First, ground yourself: WebSearch/WebFetch/Task subagents,\n\
          \Read provided code paths. Then call `pot agent plan` with\n\
          \your approach and wait for approval.\n\
          \\n\
          \After approval, write the design as `findings.md` via\n\
          \repeated `pot agent finding` calls. Cite sources.\n"
      }
  Review ->
    KindSpec
      { ksTools = ["Bash(pot agent *)", "Read", "Grep", "Glob"]
      , ksDefaultMode = Ask
      , ksDefaultPermission = PMBypassPermissions
      , ksPromptAddendum =
          "This is a `review` task. You may read files and grep but MUST\n\
          \NOT modify anything in the repository.\n\
          \\n\
          \Produce your review as `findings.md` via `pot agent finding`\n\
          \calls. Use `pot agent ask` to clarify intent.\n"
      }
  General ->
    KindSpec
      { ksTools = ["Bash(pot agent *)", "Read"]
      , ksDefaultMode = Ask
      , ksDefaultPermission = PMBypassPermissions
      , ksPromptAddendum =
          "This is a `general` task. The task body describes what the\n\
          \user wants. You have minimal tools by default; use\n\
          \`pot agent ask` liberally to clarify and propose. If the task\n\
          \asks for capabilities beyond your current toolset, explain\n\
          \and call `pot agent blocked --reason \"need tools: ...\"`.\n"
      }
