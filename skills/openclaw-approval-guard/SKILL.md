---
name: openclaw-approval-guard
description: Enforce approval-gated shell execution for OpenClaw exec tool calls, with hard approval for medium/high/critical risks and soft 10-second intercept window for key OpenClaw config writes. Use when you need command safety, anti-prompt-injection guardrails, or operator approval workflows in Telegram.
---

# OpenClaw Approval Guard

Use `scripts/run-with-approval.sh` as the execution entrypoint for shell commands.

## Setup

Use one-shot installer:

```bash
bash scripts/install.sh
```

Installer does:
- prompt bot token (if not provided in `APPROVAL_BOT_TOKEN`)
- validate token via `getMe`
- wait for user to send bot message and auto-detect `chat_id`
- write runtime config to `~/.openclaw/approval-guard/config.json`
- install plugin hook to `~/.openclaw/extensions/approval-guard-full`
- restart gateway

## Run

```bash
bash ~/.openclaw/approval-guard/run-with-approval.sh "<command>"
```

## Behavior

- `low` risk: execute directly.
- `medium/high/critical`: require manual Telegram approval.
- key OpenClaw config write (low risk): send soft alert, auto-allow after 10s, allow manual intercept.

## Included scripts

- `scripts/run-with-approval.sh`
- `scripts/request-approval.sh`
- `scripts/request-soft-alert.sh`
