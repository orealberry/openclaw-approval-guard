# openclaw-approval-guard (Rust)

A safety gate for OpenClaw command execution.

Goal: turn risky shell execution from **"run immediately"** into **"visible, reviewable, and controllable"**.

中文简介：[README_zh-CN.md](./README_zh-CN.md)

---

## What this project does

### 1) Hard Guard for risky commands
Commands assessed as `medium / high / critical` require Telegram approval:
- ✅ Approve → execute
- ⛔ Reject → block
- Timeout → reject by default

Pending approval messages are pinned until resolved, so they are harder to bury with chat noise.

### 2) Soft Guard for key OpenClaw config writes
For low-risk commands that still look like key config mutations:
- default auto-allow after 10 seconds
- one-click intercept during that window

This balances safety with productivity.

### 3) Bilingual UX (Chinese / English)
During install, user selects:
1. Chinese (简体中文)
2. English

Approval and alert card text follows the selected language.

### 4) Auto-detect key paths
Installer attempts to detect key OpenClaw targets from local runtime status/config and merges sensible defaults.

### 5) Auto hook integration
Installer writes and enables a `before_tool_call` plugin so `exec` calls are routed through this guard automatically.

---

## Security model

> If you run a newer OpenClaw version with built-in Exec Approvals, consider using the official approval flow first. This project is an additional guard layer.

- Sensitive values are required from environment variables:
  - `APPROVAL_BOT_TOKEN`
  - `APPROVAL_CHAT_ID`
- Secrets are not intended to be committed to repository files.
- Runtime config file permission is tightened on Linux (`0600`).

---

## One-line install (beginner)

### Linux / macOS

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/orealberry/openclaw-approval-guard/main/scripts/one-click-install.sh)"
```

### Windows (PowerShell)

```powershell
iwr https://raw.githubusercontent.com/orealberry/openclaw-approval-guard/main/scripts/one-click-install.ps1 -OutFile one-click-install.ps1; ./one-click-install.ps1
```

> **Note:** The first Rust build compiles many dependencies and can take several minutes. This is normal.

The script will:
1. install Rust if missing
2. clone repo and build release binary
3. install binary to `~/.local/bin/openclaw-approval-guard`
4. guide setup (token/chat detection)
5. install hook plugin and restart gateway

---

## Manual install (advanced)

```bash
git clone https://github.com/orealberry/openclaw-approval-guard.git
cd openclaw-approval-guard
cargo build --release
./target/release/openclaw-approval-guard install
```

---

## Secrets & environment variables

By default, `install` stores token/chat locally (config file permission is tightened on Linux).  
You can still override at runtime with env vars:

```bash
export APPROVAL_BOT_TOKEN='...'
export APPROVAL_CHAT_ID='...'
```

Optional install-time language override:

```bash
export APPROVAL_LANG='en'   # or zh
```

---

## Usage

```bash
openclaw-approval-guard run "sudo id"
```

```bash
openclaw-approval-guard run "cp /root/.openclaw/openclaw.json /root/.openclaw/openclaw.json.bak"
```

---

## Doctor

```bash
openclaw-approval-guard doctor
```

---

## Good fit if you want

- defense-in-depth against prompt-injection-triggered dangerous commands
- human approval for sensitive actions, without blocking all automation
- clear and auditable operator workflow for critical command execution
