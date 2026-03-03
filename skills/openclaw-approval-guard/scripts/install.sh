#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$HOME/.openclaw/approval-guard"
CONFIG_PATH="$RUNTIME_DIR/config.json"
PLUGIN_DIR="$HOME/.openclaw/extensions/approval-guard-full"

need_bin() { command -v "$1" >/dev/null 2>&1 || { echo "[error] missing binary: $1" >&2; exit 1; }; }
need_bin curl; need_bin jq; need_bin openclaw

mkdir -p "$RUNTIME_DIR" "$PLUGIN_DIR"

cp "$SKILL_DIR/references/config.example.json" "$CONFIG_PATH".tmp

TOKEN="${APPROVAL_BOT_TOKEN:-}"
if [[ -z "$TOKEN" ]]; then
  read -rsp "Enter Telegram bot token (from BotFather): " TOKEN
  echo
fi

if [[ -z "$TOKEN" ]]; then
  echo "[error] empty token" >&2
  exit 1
fi

ME=$(curl -s "https://api.telegram.org/bot$TOKEN/getMe")
if [[ "$(echo "$ME" | jq -r '.ok // false')" != "true" ]]; then
  echo "[error] token validation failed" >&2
  echo "$ME" >&2
  exit 1
fi
BOT_USER=$(echo "$ME" | jq -r '.result.username // "(unknown)"')

echo "[ok] bot validated: @$BOT_USER"

echo "[step] Open Telegram and send any message to @$BOT_USER"
echo "       Then press Enter here to continue."
read -r

BASE=$(curl -s "https://api.telegram.org/bot$TOKEN/getUpdates" | jq '.result[-1].update_id // 0')
OFFSET=$((BASE + 1))

echo "[step] waiting for your next message to @$BOT_USER (timeout: 120s)..."
CHAT_ID=""
DEADLINE=$(( $(date +%s) + 120 ))
while (( $(date +%s) < DEADLINE )); do
  RESP=$(curl -s "https://api.telegram.org/bot$TOKEN/getUpdates" -d offset="$OFFSET" -d timeout=10)
  LAST=$(echo "$RESP" | jq '.result[-1].update_id // null')
  if [[ "$LAST" != "null" && -n "$LAST" ]]; then
    OFFSET=$((LAST + 1))
  fi
  CHAT_ID=$(echo "$RESP" | jq -r '.result[]?.message?.chat?.id // empty' | head -n1)
  if [[ -n "$CHAT_ID" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "$CHAT_ID" ]]; then
  echo "[error] chat id detection timed out. You can set APPROVAL_CHAT_ID manually later." >&2
  exit 1
fi

echo "[ok] detected chat_id: $CHAT_ID"

jq --arg t "$TOKEN" --arg c "$CHAT_ID" '.bot_token=$t | .approver_chat_id=$c' "$CONFIG_PATH".tmp > "$CONFIG_PATH"
rm -f "$CONFIG_PATH".tmp

cp "$SKILL_DIR/scripts/request-approval.sh" "$RUNTIME_DIR/request-approval.sh"
cp "$SKILL_DIR/scripts/request-soft-alert.sh" "$RUNTIME_DIR/request-soft-alert.sh"
cp "$SKILL_DIR/scripts/run-with-approval.sh" "$RUNTIME_DIR/run-with-approval.sh"
chmod +x "$RUNTIME_DIR"/*.sh

cat > "$PLUGIN_DIR/openclaw.plugin.json" <<'JSON'
{
  "id": "approval-guard-full",
  "name": "Approval Guard Full",
  "description": "Intercept exec tool calls and route them through approval wrapper",
  "configSchema": {}
}
JSON

cat > "$PLUGIN_DIR/index.ts" <<'TS'
const WRAPPER = "__WRAPPER__";

function shQuote(s: string): string {
  return `'${s.replace(/'/g, `'"'"'`)}'`;
}

export default function register(api: any) {
  api.registerHook(
    "before_tool_call",
    async (event: any, ctx: any) => {
      const toolName = String(event?.toolName ?? ctx?.toolName ?? "");
      if (toolName !== "exec") return;
      const params = (event?.params ?? {}) as Record<string, unknown>;
      const command = typeof params.command === "string" ? params.command : "";
      if (!command.trim()) return;
      if (command.includes(WRAPPER)) return;
      return { params: { ...params, command: `bash ${shQuote(WRAPPER)} ${shQuote(command)}` } };
    },
    { name: "approval-guard-full.before-tool-call", description: "Route exec command through approval wrapper" },
  );
}
TS
sed -i "s|__WRAPPER__|$RUNTIME_DIR/run-with-approval.sh|g" "$PLUGIN_DIR/index.ts"

echo "[step] restarting gateway..."
openclaw gateway restart >/dev/null 2>&1 || true

echo "[done] installed."
echo "  config: $CONFIG_PATH"
echo "  plugin: $PLUGIN_DIR"
echo "  test:   bash $RUNTIME_DIR/run-with-approval.sh \"sudo id\""
