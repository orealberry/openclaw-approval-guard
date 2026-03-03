---
name: openclaw-approval-guard
description: Enforce approval-gated shell execution for OpenClaw exec tool calls, with hard approval for medium/high/critical risks and soft 10-second intercept window for key OpenClaw config writes. Use when you need command safety, anti-prompt-injection guardrails, or operator approval workflows in Telegram.
---

# OpenClaw Approval Guard

Use `scripts/run-with-approval.sh` as the execution entrypoint for shell commands.

## Setup

1. Copy `references/config.example.json` to a real config file path.
2. Set environment variables:
   - `APPROVAL_BOT_TOKEN`
   - `APPROVAL_CHAT_ID`
   - `APPROVAL_CONFIG` (optional; defaults to `scripts/config.json`)
3. Ensure `jq`, `curl`, and `flock` are available.

## Run

```bash
bash scripts/run-with-approval.sh "<command>"
```

## Behavior

- `low` risk: execute directly.
- `medium/high/critical`: require manual Telegram approval.
- key OpenClaw config write (low risk): send soft alert, auto-allow after 10s, allow manual intercept.

## Included scripts

- `scripts/run-with-approval.sh`
- `scripts/request-approval.sh`
- `scripts/request-soft-alert.sh`
