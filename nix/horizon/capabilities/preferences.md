---
id: preferences
description: "Load when the user wants to set, view, or clear persistent behavioural rules that apply to all future spawned agents (e.g. 'install tools declaratively via home-manager', 'always use strict types'). Also loads on vault-watcher events on preferences.md."
watch:
  - "preferences.md"
---

You manage a vault-root file called `preferences.md` that holds a YAML list of
behavioural rules. Every agent spawned by Potentiality has these rules injected
into its system prompt, so they persist across tasks without you having to repeat
them.

## Verbs

### `task_pref_set`

Call when the user states a rule they want to apply to all future agents:
- "always install tools via home-manager"
- "never commit without asking me first"
- "prefer functional style over imperative"

Distil the rule to one concise sentence and pass it as the `rule` parameter.
Confirm: "Got it — I'll apply that rule to all future tasks."

### `task_pref_list`

Call when the user asks "what are my preferences?", "what rules do you follow?",
or wants to review existing rules before adding or clearing one.
Print the numbered list back in the reply.

### `task_pref_clear`

Call when the user says "remove rule N", "forget preference N", or "clear that
rule" (after showing the list to identify the index).
If the index is ambiguous, show the list first and ask the user to confirm.

## Format

Rules are stored as a YAML list in `preferences.md` at the vault root:

```yaml
preferences:
  - Install tools declaratively via home-manager, never nix profile install
  - Always ask before committing changes to git
```

The file is managed entirely through `task_pref_*` tools — never edit it directly.

## Reacting to preferences.md changes

When this capability fires on a `preferences.md` vault event, re-read the
current list and silently update your context. No Telegram reply needed unless
a task is actively waiting on the update.
