# openclaw-approval-guard（中文简介）

这是一个用于 OpenClaw 的命令审批守卫（Rust 版）：

- 对 medium/high/critical 风险命令执行 **人工审批**
- 对关键配置写入提供 **软拦截**（默认 10 秒自动放行，可手动拦截）
- Telegram 按钮审批 + 置顶提示
- 自动安装 `before_tool_call` Hook

## 一键安装（新手）

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/orealberry/openclaw-approval-guard/main/scripts/one-click-install.sh)"
```

## 手动安装（进阶）

```bash
git clone https://github.com/orealberry/openclaw-approval-guard.git
cd openclaw-approval-guard
cargo build --release
./target/release/openclaw-approval-guard install
```

## 使用前环境变量（敏感信息）

```bash
export APPROVAL_BOT_TOKEN='...'
export APPROVAL_CHAT_ID='...'
```

## 运行示例

```bash
openclaw-approval-guard run "sudo id"
```
