# Approval Hook Skeleton

Goal: gate **high-risk commands** behind a Telegram approval bot (`@hookapprovalbot`).

## Files
- `config.json` — fill in your bot token and target `chat_id` (approver). 
- `request-approval.sh` — send approval request (with inline buttons) and poll for result.
- `request-soft-alert.sh` — soft-guard reminder for OpenClaw key config edits (default 10s auto-allow, can intercept).
- `run-with-approval.sh` — wrapper: classify risk → high/medium/critical require approval; low risk may trigger soft-guard for key config writes.
- `state/` — local offsets/state (ignored by git).

## Setup
1) Edit `config.json`:
```json
{
  "bot_token": "<REDACTED_BOT_TOKEN>",
  "approver_chat_id": "<fill_your_chat_id>",
  "timeout_sec": 300,
  "risk_patterns": [
    "rm -rf /",
    "rm -rf /root",
    "dd if=/dev/zero",
    "mkfs",
    ":(){:|:&};:",
    "shutdown -h",
    "reboot",
    "chmod 777 /",
    "chown -R ",
    "iptables",
    "ufw delete",
    "systemctl stop",
    "curl .* | sh",
    "wget .* | sh"
  ]
}
```
- `bot_token` 已填（你提供的）。
- 把 `approver_chat_id` 改成你自己/审批群的 chat id。
- `timeout_sec` 默认 300 秒。
- `risk_patterns` 可扩展。

2) 获取 `chat_id`：给 bot 发一条消息，然后调用：
```bash
curl -s "https://api.telegram.org/bot<bot_token>/getUpdates" | jq '.result[] | .message.chat.id'
```
把结果填进 `config.json`。

3) 本地测试
```bash
cd ops/approval
bash run-with-approval.sh "rm -rf /tmp/test"   # 高危，需审批
bash run-with-approval.sh "echo ok"            # 非高危，直接执行
```

## 集成思路（待接入 OpenClaw hooks）
- 将 `run-with-approval.sh` 作为 pre-tool hook 调用，检测即将执行的 shell command/工具参数。
- 拦截命中高危模式的调用 → 发送审批 → 等待结果 → 执行/拒绝。
- 超时自动拒绝并记录。

目前代码是可运行的本地脚本，后续可按 OpenClaw hook 规范包一层即可。
