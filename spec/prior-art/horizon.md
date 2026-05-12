# Prior art — Horizon (the chat surface we delegate to)

Notes on [purplenoodlesoop/horizon](https://github.com/purplenoodlesoop/horizon) — the user's existing personal-assistant project. Horizon is *peer infrastructure* to Potentiality, not a dependency. We design Potentiality on the assumption that Horizon already provides the chat/mobile UI and the vault, but Potentiality must be useful without Horizon running.

## What Horizon is

A personal multi-agent assistant. Single Dart binary (~5.8k LOC). Reads events from CLI stdin or a Telegram bot (with username allowlist) and uses an LLM to operate on a Markdown vault. The vault doubles as memory: capabilities, system prompts, and tool allowlist live as editable `.md` / `.yaml` files under `<vault>/_horizon/`. Tools are bash command templates with shell-escaped parameters — **explicitly not MCP**. No database; state is files.

License: MIT. Active (Phase 7+, daily commits, last update May 2026).

## Stack

| Layer | Choice |
|---|---|
| Language | Dart 3.4+ |
| Key deps (`pubspec.yaml`) | `openai_dart ^4.0.1`, `http ^1.4.0`, `args`, `yaml`, `freezed_annotation`, `fast_immutable_collections`, `mark`, `fn`, `pure` |
| Build | `dart compile exe bin/horizon.dart` |
| Distribution | Nix flake (`nix run github:purplenoodlesoop/horizon`) |
| Landing page | Static, Cloudflare Pages (`wrangler.toml`) at horizon.yakov.codes |

## Internal domain types

(in `lib/src/`)

- `capability/capability.dart` — `Capability { id, description, schedule?, body }`
- `event/event.dart` — sealed `Event` (CLI, Telegram inbound, Telegram inline, Heartbeat)
- `harness/message_store.dart`, `turn_store.dart` — Markdown files under `_horizon/messages/`, `_horizon/turns/`
- `tool/allowlist.dart` — `AllowlistedTool { name, description, parameters: {name → {type, description}}, command }`
- `agent/agent_event.dart` — streaming `AgentReasoningDelta`, `AgentTextDelta`, `AgentToolStarted`, `AgentToolFinished`, `AgentFinished`
- `config/config.dart`, `config/env_store.dart` — paths and rotating env

These are internal. The relevant *external* contract is what Horizon expects on the wire.

## Horizon's outbound protocol

Horizon talks to exactly one server: an **OpenAI-compatible chat completions endpoint over HTTPS with SSE streaming**.

- Endpoint: `POST {LLM_URL}/chat/completions`
- Headers: `Authorization: Bearer <LLM_TOKEN>`, `Content-Type: application/json`, `Accept: text/event-stream`
- Body: standard OpenAI chat-completions JSON — `model`, `messages`, `tools`. No `temperature`, `tool_choice`, `response_format` set.
- Response: SSE stream `data: {…}\n\n` chunks; final chunk includes `usage` with `prompt_tokens_details.cached_tokens` when supported.

Confirmed by reading `lib/src/llm/client.dart:67-71`:

```dart
final client = OpenAIClient.withApiKey(
  envStore.llmToken,
  baseUrl: envStore.llmUrl,
);
```

Default `LLM_URL = https://crof.ai/v1`, `LLM_MODEL = kimi-k2.6`. Hot-reloads from `.env`.

### Key implication for Potentiality

**Horizon does NOT speak any of Symphony's, ACP's, or openclaw-code-agent's protocols.** The user's framing of "talk to Potentiality from Horizon" cannot mean Horizon-as-client-of-Potentiality-orchestration-API, because Horizon has only one protocol-client and it's OpenAI chat completions.

The resolution: Horizon and Potentiality **do not talk over a wire at all.** They share the vault. This is the central architectural decision Potentiality makes, derived from this constraint.

## Agentic loop is client-side

Horizon receives `tool_calls` in the assistant message, executes them locally as bash commands (from `tool/allowlist.dart`), appends a `role: "tool"` message, re-POSTs. The server never sees tool execution.

This is critical for Potentiality: when Horizon's chat LLM calls a tool like `task_new`, it's running `bash -c "pot do new ..."` *on Horizon's host*. The LLM-server doesn't know about Potentiality. Potentiality and Horizon are peer processes on the same machine, both touching the same vault.

## Mobile UX

- Telegram bot (with username allowlist) — primary mobile surface
- Telegram inline buttons, deep-linking, file uploads (up to 2 GB), inline mode
- Multimodal: photos turn into `image_url` parts in the chat completions request
- CLI stdin loop for desktop testing

## Distribution

- Nix flake; the flake takes [`purplenoodlesoop/core-flake`](https://github.com/purplenoodlesoop/core-flake) as an input. Same pattern Potentiality will adopt.
- `nix run github:purplenoodlesoop/horizon` works out-of-the-box (templates baked in via `HORIZON_TEMPLATES`).

## What Horizon already does that Potentiality leverages

| Capability | Horizon already has it |
|---|---|
| Watch the Markdown vault for changes | ✓ (`env_watcher.dart` for env; vault-wide watcher for capabilities/allowlist) |
| Execute bash commands with shell-escaped parameters | ✓ (`tool/` module) |
| Telegram bot with allowlist, inline keyboards, deep-linking, multimodal | ✓ |
| Stream LLM output, route through Telegram live edits | ✓ (Phase 6/7) |
| Voice memos, schedules, admin commands | ✓ (Phase 7) |
| Hot-reload from `.env` | ✓ |

This means Potentiality does **not** need to:

- Build any chat UI
- Implement Telegram bot logic
- Handle voice / multimodal
- Manage user authentication
- Build a mobile app
- Build a web dashboard

It needs to:

- Define file conventions Horizon can read and write
- Provide a CLI Horizon can shell out to (`pot do *`)
- Provide a CLI the agent can shell out to (`pot agent *`)
- Run the agent (Claude Code)

## What Horizon needs to add to integrate

Documented in [08-horizon-integration.md](../08-horizon-integration.md). Summary:

1. ~6 new entries in `_horizon/system/allowlist.yaml` (the `task_new` / `task_show` / etc. command templates)
2. Extend the existing vault watcher to recognize 3 new file patterns (new question, new plan, status changed)
3. Telegram-thread-to-task binding logic (store `chat_id` + `thread_id` in `meta.yaml`, route replies)

No internal refactor. Additive only.

## Why this delegation works

The user has *already* solved the hardest part of "give me a self-hosted personal AI on a server I can chat with from anywhere": Horizon does that. What's missing is the *coding-agent runner* half. Potentiality fills exactly that gap and nothing more.

The boundary is the vault. Both sides watch it. Both sides write it. Neither imports the other.
