# openclaw-approval-guard (Rust)

Rust rewrite of OpenClaw approval guard:
- hard approval for medium/high/critical shell risks
- soft 10s intercept for key OpenClaw config writes
- Telegram callback workflow with pin/unpin behavior
- OpenClaw `before_tool_call` hook installer

## One-line install (beginner)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/orealberry/openclaw-approval-guard/main/scripts/one-click-install.sh)"
```

This script will:
1. install Rust automatically if missing
2. clone repo and build release binary
3. install binary to `~/.local/bin/openclaw-approval-guard`
4. run interactive setup (ask token, auto-detect chat_id)
5. install hook plugin and restart gateway

## Manual install (advanced)

```bash
git clone https://github.com/orealberry/openclaw-approval-guard.git
cd openclaw-approval-guard
cargo build --release
./target/release/openclaw-approval-guard install
```

## Usage

```bash
openclaw-approval-guard run "sudo id"
```

## Doctor

```bash
openclaw-approval-guard doctor
```
