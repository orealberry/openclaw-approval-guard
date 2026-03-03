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
TIMEOUT_SEC=$(jget '.timeout_sec // 300')

if [[ -z "$BOT_TOKEN" || "$BOT_TOKEN" == "null" ]]; then
  echo "[error] bot_token missing in config.json" >&2; exit 1; fi
if [[ -z "$CHAT_ID" || "$CHAT_ID" == "null" || "$CHAT_ID" == "<fill_your_chat_id>" ]]; then
  echo "[error] approver_chat_id not set in config.json" >&2; exit 2; fi

REQ_ID="req-$(date +%s)-$RANDOM"
CMD="$1"
RISK="${2:-high}"
REASON="${3:-命中高危策略}"

send_request() {
  local created_at
  created_at="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
  local text="🚨 <b>高危操作审批</b>

<b>风险等级</b> ${RISK^^}
<b>触发原因</b> $REASON

<b>命令</b>
<code>$CMD</code>

<b>请求ID</b> <code>$REQ_ID</code>
<b>时间</b> $created_at

请确认是否执行该操作："
  local keyboard='{"inline_keyboard":[[{"text":"✅ 批准执行","callback_data":"approve:'"$REQ_ID"'"},{"text":"⛔ 拒绝执行","callback_data":"reject:'"$REQ_ID"'"}]]}'
  local resp
  resp=$(curl -s "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d parse_mode="HTML" \
    --data-urlencode "text=$text" \
    -d reply_markup="$keyboard")
  echo "$resp" | jq -r '.result.message_id // empty'
}

get_offset() { [[ -f "$OFFSET_FILE" ]] && cat "$OFFSET_FILE" || echo 0; }
set_offset() { echo "$1" > "$OFFSET_FILE"; }

poll_decision() {
  local deadline=$(( $(date +%s) + TIMEOUT_SEC ))
  local offset=$(get_offset)
  while (( $(date +%s) < deadline )); do
    local resp
    resp=$(curl -s "https://api.telegram.org/bot$BOT_TOKEN/getUpdates" \
      -d offset="$offset" -d timeout=20)
    local new_offset=$(echo "$resp" | jq '.result[-1].update_id // null')
    if [[ "$new_offset" != "null" && -n "$new_offset" ]]; then
      offset=$((new_offset + 1))
      set_offset "$offset"
    fi
    local decision
    decision=$(echo "$resp" | jq -rc \
      --arg rid "$REQ_ID" \
      'if .result then (.result[]
         | select(.callback_query and (.callback_query.data? | type=="string")
           and ((.callback_query.data|startswith("approve:" + $rid)) or (.callback_query.data|startswith("reject:" + $rid))))
         | {data: .callback_query.data, cbid: .callback_query.id}) else empty end' 2>/dev/null | head -n1)
    if [[ -n "$decision" ]]; then
      echo "$decision"
      return 0
    fi
  done
  echo "timeout"
}

answer_callback() {
  local cbid="$1"; local text="$2"
  [[ -z "$cbid" ]] && return
  curl -s "https://api.telegram.org/bot$BOT_TOKEN/answerCallbackQuery" \
    -d callback_query_id="$cbid" \
    --data-urlencode "text=$text" >/dev/null || true
}

pin_message() {
  local message_id="$1"
  [[ -z "$message_id" ]] && return
  curl -s "https://api.telegram.org/bot$BOT_TOKEN/pinChatMessage" \
    -d chat_id="$CHAT_ID" \
    -d message_id="$message_id" \
    -d disable_notification=true >/dev/null || true
}

unpin_message() {
  local message_id="$1"
  [[ -z "$message_id" ]] && return
  curl -s "https://api.telegram.org/bot$BOT_TOKEN/unpinChatMessage" \
    -d chat_id="$CHAT_ID" \
    -d message_id="$message_id" >/dev/null || true
}

log() {
  echo "$(date -Is) $1" >> "$LOG_FILE"
}

mark_message_done() {
  local message_id="$1"; local status="$2"
  [[ -z "$message_id" ]] && return
  local finished_at
  finished_at="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
  local new_text="🛡️ <b>审批已处理</b>

<b>风险等级</b> ${RISK^^}
<b>触发原因</b> $REASON

<b>命令</b>
<code>$CMD</code>

<b>请求ID</b> <code>$REQ_ID</code>
<b>结果</b> $status
<b>处理时间</b> $finished_at"
  curl -s "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" \
    -d chat_id="$CHAT_ID" \
    -d message_id="$message_id" \
    -d parse_mode="HTML" \
    --data-urlencode "text=$new_text" >/dev/null || true
}

main() {
  local message_id
  message_id=$(send_request)
  pin_message "$message_id"
  log "REQUEST $REQ_ID $CMD msg=$message_id pinned=true"

  local decision
  decision=$(poll_decision)
  local data cbid
  data=$(echo "$decision" | jq -r '.data // empty' 2>/dev/null || true)
  cbid=$(echo "$decision" | jq -r '.cbid // empty' 2>/dev/null || true)

  if [[ "$data" == approve:* ]]; then
    answer_callback "$cbid" "✅ 已批准，开始执行"
    mark_message_done "$message_id" "✅ 已批准"
    unpin_message "$message_id"
    log "APPROVED $REQ_ID"
    echo "approved"
  elif [[ "$data" == reject:* ]]; then
    answer_callback "$cbid" "⛔ 已拒绝"
    mark_message_done "$message_id" "⛔ 已拒绝"
    unpin_message "$message_id"
    log "REJECTED $REQ_ID"
    echo "rejected"
  elif [[ "$decision" == "timeout" ]]; then
    mark_message_done "$message_id" "⏳ 已超时"
    unpin_message "$message_id"
    log "TIMEOUT $REQ_ID"
    echo "timeout"
  else
    # Fail closed: any malformed/empty decision is treated as reject
    mark_message_done "$message_id" "❌ 已拒绝(无效回调)"
    unpin_message "$message_id"
    log "INVALID_OR_EMPTY_DECISION $REQ_ID"
    echo "rejected"
  fi
}

main
