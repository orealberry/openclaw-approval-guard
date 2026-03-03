# openclaw-approval-guard（中文简介）

一个给 OpenClaw 用的“命令安全闸门”（Rust 版）。
核心目标：**把高风险命令从“直接执行”改成“可审计、可审批、可拦截”**。

---

## 它能做什么？

### 1) 高风险命令强审批（Hard Guard）
对 `medium / high / critical` 风险命令，不会直接执行，而是先发到 Telegram 审批卡片：
- ✅ 批准后执行
- ⛔ 拒绝则终止
- 超时默认拒绝

并且在待处理期间会置顶，避免被消息刷屏淹没。

### 2) 关键配置软拦截（Soft Guard）
对“低风险但可能修改 OpenClaw 关键配置”的命令：
- 默认 10 秒后自动放行
- 期间可点击「拦截本次执行」终止命令

适合防止误操作，同时不影响日常效率。

### 3) 中英文双语交互
安装时可选：
1. Chinese（简体中文）
2. English

后续审批/提醒卡片会按所选语言展示。

### 4) 自动探测关键路径
安装时会尝试根据本机 OpenClaw 状态自动探测关键目标路径（如 openclaw.json、extensions、cron、gateway service），降低手动配置成本。

### 5) Hook 自动接入
安装器会自动接入 `before_tool_call`，让 `exec` 调用自动经过守卫流程，无需你手工拼 hook。

---

## 安全设计（你可能关心的点）

- **敏感信息环境变量优先/强制**：
  - `APPROVAL_BOT_TOKEN`
  - `APPROVAL_CHAT_ID`
- 不建议把 token 硬编码进仓库。
- 配置文件权限默认收紧（Linux 下 0600）。

---

## 一键安装（新手）

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/orealberry/openclaw-approval-guard/main/scripts/one-click-install.sh)"
```

> **提示：** 首次 Rust 编译会拉取并编译较多依赖，可能需要几分钟，这属于正常现象。

一键脚本会自动：
1. 检查/安装 Rust（缺失时）
2. 拉取仓库并编译 release
3. 安装二进制到 `~/.local/bin/openclaw-approval-guard`
4. 引导设置机器人信息
5. 安装 Hook 并重启 gateway

---

## 手动安装（进阶）

```bash
git clone https://github.com/orealberry/openclaw-approval-guard.git
cd openclaw-approval-guard
cargo build --release
./target/release/openclaw-approval-guard install
```

---

## 敏感信息与环境变量

默认安装流程会把 token/chat 写入本地配置（Linux 下权限收紧为 0600）。  
也支持通过环境变量在运行时覆盖：

```bash
export APPROVAL_BOT_TOKEN='...'
export APPROVAL_CHAT_ID='...'
```

如果你希望安装时直接指定英文：
```bash
export APPROVAL_LANG='en'
```

---

## 运行示例

```bash
openclaw-approval-guard run "sudo id"
```

```bash
openclaw-approval-guard run "cp /root/.openclaw/openclaw.json /root/.openclaw/openclaw.json.bak"
```

---

## 诊断

```bash
openclaw-approval-guard doctor
```

---

## 适用场景

- 你担心提示词注入导致危险命令被执行
- 你希望“能自动化，但关键动作必须可控”
- 你希望每次敏感变更都有可见审批流程
- 多人共用设备/账号，想降低误触与越权风险
