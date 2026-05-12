# Potentiality

Haskell agent runner over a Markdown vault. Symphony-inspired, Claude Code–backed, chat-client agnostic.

Status: pre-alpha. The spec is the deliverable; implementation in progress.

## What it is

A single static binary, `pot`, that watches a directory of Markdown task files, claims any task marked `ready`, runs Claude Code against the named working directory, and writes the result back into the same vault.

Designed to be paired with any vault-aware chat client. The two reference integrations are [`purplenoodlesoop/horizon`](https://github.com/purplenoodlesoop/horizon) (single-binary, Telegram-native) and [`openclaw/openclaw`](https://github.com/openclaw/openclaw) (multi-channel: Telegram, Slack, Discord, WhatsApp, iMessage, Matrix, …) via a small skill. Anything that can watch files and run bash works. See [`spec/08-chat-client-integration.md`](./spec/08-chat-client-integration.md) for the contract.

## Design

See [`spec/`](./spec/) for the full design. Start with [`spec/README.md`](./spec/README.md) for the table of contents, [`spec/00-overview.md`](./spec/00-overview.md) for the elevator pitch, and [`spec/01-philosophy.md`](./spec/01-philosophy.md) for the rules that decide arguments.

For what the implementation does *not* yet do, see [`LIMITATIONS.md`](./LIMITATIONS.md).

## Run

```
nix run github:purplenoodlesoop/potentiality -- --version
```

(Phase 1: prints the version and exits.)

## License

MIT.
