# openclaw-approval-guard (Rust)

Rust rewrite of OpenClaw approval guard:
- hard approval for medium/high/critical shell risks
- soft 10s intercept for key OpenClaw config writes
- Telegram callback workflow with pin/unpin behavior
- OpenClaw `before_tool_call` hook installer

## Build

```bash
cargo build --release
```

## Install

```bash
./target/release/approval-guard install
```

The installer will:
1. ask for bot token
2. validate token
3. auto-detect chat_id from Telegram message
4. write runtime config to `~/.openclaw/approval-guard/config.json`
5. install OpenClaw extension hook to `~/.openclaw/extensions/approval-guard-full`
6. restart gateway

## Run manually

```bash
./target/release/approval-guard run --command "sudo id"
```

## Doctor

```bash
./target/release/approval-guard doctor
```
