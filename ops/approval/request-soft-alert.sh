#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/config.json"
STATE_DIR="$HERE/state"
OFFSET_FILE="$STATE_DIR/offset.txt"
LOG_FILE="$HERE/approval.log"
mkdir -p "$STATE_DIR"

jget() { jq -r "$1" "$CONFIG"; }
BOT_TOKEN=$(jget '.bot_token')
CHAT_ID=$(jget '.approver_chat_id')
TIMEOUT_SEC=$(jget '.soft_guard_timeout_sec // 10')

if [[ -z "$BOT_TOKEN" || "$BOT_TOKEN" == "null" ]]; then
  echo "[error] bot_token missing in config.json" >&2; exit 1; fi
if [[ -z "$CHAT_ID" || "$CHAT_ID" == "null" || "$CHAT_ID" == "<fill_your_chat_id>" ]]; then
  echo "[error] approver_chat_id not set in config.json" >&2; exit 2; fi

REQ_ID="soft-$(date +%s)-$RANDOM"
CMD="$1"

get_offset() { [[ -f "$OFFSET_FILE" ]] && cat "$OFFSET_FILE" || echo 0; }
set_offset() { echo "$1" > "$OFFSET_FILE"; }

log() { echo "$(date -Is) $1" >> "$LOG_FILE"; }

send_alert() {
  local created_at
  created_at="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
  local text="⚠️ <b>关键配置修改提醒</b>

检测到命令可能修改 OpenClaw 关键配置：
<code>$CMD</code>

<b>策略</b>
• 默认 ${TIMEOUT_SEC} 秒后自动放行
• 若要拦截本次执行，请点击下方按钮

<b>请求ID</b> <code>$REQ_ID</code>
<b>时间</b> $created_at"
  local keyboard='{"inline_keyboard":[[{"text":"🛑 拦截本次执行","callback_data":"abort:'"$REQ_ID"'"}]]}'
  local resp
  resp=$(curl -s "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d parse_mode="HTML" \
    --data-urlencode "text=$text" \
    -d reply_markup="$keyboard")
  echo "$resp" | jq -r '.result.message_id // empty'
}

answer_callback() {
  local cbid="$1"; local text="$2"
  [[ -z "$cbid" ]] && return
  curl -s "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" \
    -d callback_query_id="$cbid" \
    --data-urlencode "text=$text" >/dev/null || true
}

mark_done() {
  local message_id="$1"; local status="$2"
  [[ -z "$message_id" ]] && return
  local finished_at
  finished_at="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
  local text="🛡️ <b>配置修改提醒已处理</b>

<code>$CMD</code>

<b>请求ID</b> <code>$REQ_ID</code>
<b>结果</b> $status
<b>处理时间</b> $finished_at"
  curl -s "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" \
    -d chat_id="$CHAT_ID" \
    -d message_id="$message_id" \
    -d parse_mode="HTML" \
    --data-urlencode "text=$text" >/dev/null || true
}

poll_abort() {
  local deadline=$(( $(date +%s) + TIMEOUT_SEC ))
  local offset
  offset=$(get_offset)
  while (( $(date +%s) < deadline )); do
    local resp
    resp=$(curl -s "https://api.telegram.org/bot$BOT_TOKEN/getUpdates" \
      -d offset="$offset" -d timeout=2)
    local new_offset
    new_offset=$(echo "$resp" | jq '.result[-1].update_id // null')
    if [[ "$new_offset" != "null" && -n "$new_offset" ]]; then
      offset=$((new_offset + 1))
      set_offset "$offset"
    fi

    local hit
    hit=$(echo "$resp" | jq -rc --arg rid "$REQ_ID" '
      if .result then (.result[]
        | select(.callback_query and (.callback_query.data? | type=="string") and (.callback_query.data|startswith("abort:" + $rid)))
        | {data:.callback_query.data, cbid:.callback_query.id}) else empty end' 2>/dev/null | head -n1)
    if [[ -n "$hit" ]]; then
      echo "$hit"
      return 0
    fi
    sleep 1
  done
  echo "timeout"
}

main() {
  local message_id
  message_id=$(send_alert)
  log "SOFT_ALERT_REQUEST $REQ_ID msg=$message_id cmd=$(printf %q "$CMD")"

  local res data cbid
  res=$(poll_abort)
  data=$(echo "$res" | jq -r '.data // empty' 2>/dev/null || true)
  cbid=$(echo "$res" | jq -r '.cbid // empty' 2>/dev/null || true)

  if [[ "$data" == abort:* ]]; then
    answer_callback "$cbid" "🛑 已拦截，本次命令终止"
    mark_done "$message_id" "🛑 已拦截"
    log "SOFT_ALERT_ABORTED $REQ_ID"
    echo "blocked"
  else
    mark_done "$message_id" "✅ 超时自动放行"
    log "SOFT_ALERT_AUTO_ALLOW $REQ_ID"
    echo "allowed"
  fi
}

main
