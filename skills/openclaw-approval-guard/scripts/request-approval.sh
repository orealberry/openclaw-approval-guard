#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${APPROVAL_CONFIG:-$HERE/config.json}"
STATE_DIR="$HERE/state"
LOG_FILE="$HERE/approval.log"
UPDATES_LOCK_FILE="$STATE_DIR/updates.lock"
mkdir -p "$STATE_DIR"

jget() { jq -r "$1" "$CONFIG"; }
BOT_TOKEN="${APPROVAL_BOT_TOKEN:-$(jget '.bot_token // empty')}"
CHAT_ID="${APPROVAL_CHAT_ID:-$(jget '.approver_chat_id // empty')}"
TIMEOUT_SEC=$(jget '.timeout_sec // 300')

if [[ -z "$BOT_TOKEN" || "$BOT_TOKEN" == "null" ]]; then
  echo "[error] bot_token missing in config.json" >&2; exit 1; fi
if [[ -z "$CHAT_ID" || "$CHAT_ID" == "null" || "$CHAT_ID" == "<fill_your_chat_id>" ]]; then
  echo "[error] approver_chat_id not set in config.json" >&2; exit 2; fi

REQ_ID="req-$(date +%s)-$RANDOM"
CMD="$1"
RISK="${2:-high}"
REASON="${3:-命中高危策略}"

explain_command() {
  local c="$1"
  if echo "$c" | grep -qE '^rm[[:space:]]+-rf'; then
    echo "解读：rm -rf 是递归强制删除命令，误用可能造成不可逆数据丢失。"
  elif echo "$c" | grep -qE 'dd[[:space:]]+if='; then
    echo "解读：dd 可进行底层块设备读写，写错目标可能直接破坏磁盘数据。"
  elif echo "$c" | grep -qE 'mkfs\.'; then
    echo "解读：mkfs 会格式化文件系统，目标分区数据会被清空。"
  elif echo "$c" | grep -qE '(curl|wget).*\|[[:space:]]*(bash|sh|python)'; then
    echo "解读：下载后直接管道执行脚本，存在供应链与远程代码执行风险。"
  elif echo "$c" | grep -qE 'chmod[[:space:]]+777'; then
    echo "解读：chmod 777 会让所有用户可读写执行，权限过宽有安全风险。"
  elif echo "$c" | grep -qE 'sudo[[:space:]]+'; then
    echo "解读：sudo 将以特权运行命令，操作影响范围与破坏面会扩大。"
  elif echo "$c" | grep -qE 'iptables|firewall-cmd|ufw'; then
    echo "解读：防火墙规则变更可能导致远程连接中断或服务暴露。"
  elif echo "$c" | grep -qE 'systemctl[[:space:]]+stop'; then
    echo "解读：停止系统服务可能导致业务中断或守护进程失效。"
  else
    echo "解读：该命令可能影响系统状态，请确认目标与参数无误后再执行。"
  fi
}

send_request() {
  local created_at
  created_at="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
  local advice
  advice="$(explain_command "$CMD")"
  local text="🚨 <b>高危操作审批</b>

<b>风险等级</b> ${RISK^^}
<b>触发原因</b> $REASON

<b>命令</b>
<code>$CMD</code>

<b>请求ID</b> <code>$REQ_ID</code>
<b>时间</b> $created_at

<b>建议解读</b>
$advice

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

poll_decision() {
  local deadline=$(( $(date +%s) + TIMEOUT_SEC ))

  # Serialize Telegram update consumption to avoid cross-request races.
  exec 9>"$UPDATES_LOCK_FILE"
  if ! flock -w 5 9; then
    log "LOCK_TIMEOUT $REQ_ID"
    echo "timeout"
    return 0
  fi

  local baseline_resp baseline offset
  baseline_resp=$(curl -s "https://api.telegram.org/bot$BOT_TOKEN/getUpdates" -d timeout=0)
  baseline=$(echo "$baseline_resp" | jq '.result[-1].update_id // 0')
  offset=$((baseline + 1))

  while (( $(date +%s) < deadline )); do
    local resp
    resp=$(curl -s "https://api.telegram.org/bot$BOT_TOKEN/getUpdates" \
      -d offset="$offset" -d timeout=20)
    local new_offset
    new_offset=$(echo "$resp" | jq '.result[-1].update_id // null')
    if [[ "$new_offset" != "null" && -n "$new_offset" ]]; then
      offset=$((new_offset + 1))
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
      flock -u 9
      return 0
    fi
  done

  flock -u 9
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
  local resp ok
  resp=$(curl -s "https://api.telegram.org/bot$BOT_TOKEN/pinChatMessage" \
    -d chat_id="$CHAT_ID" \
    -d message_id="$message_id" \
    -d disable_notification=true || true)
  ok=$(echo "$resp" | jq -r '.ok // false' 2>/dev/null || echo false)
  if [[ "$ok" != "true" ]]; then
    log "PIN_FAILED $REQ_ID msg=$message_id resp=$(printf %q "$resp")"
  fi
}

unpin_message() {
  local message_id="$1"
  [[ -z "$message_id" ]] && return
  local resp ok
  resp=$(curl -s "https://api.telegram.org/bot$BOT_TOKEN/unpinChatMessage" \
    -d chat_id="$CHAT_ID" \
    -d message_id="$message_id" || true)
  ok=$(echo "$resp" | jq -r '.ok // false' 2>/dev/null || echo false)
  if [[ "$ok" != "true" ]]; then
    log "UNPIN_FAILED $REQ_ID msg=$message_id resp=$(printf %q "$resp")"
  fi
}

log() {
  echo "$(date -Is) $1" >> "$LOG_FILE"
}

mark_message_done() {
  local message_id="$1"; local status="$2"
  [[ -z "$message_id" ]] && return
  local finished_at
  finished_at="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
  local advice
  advice="$(explain_command "$CMD")"
  local new_text="🛡️ <b>审批已处理</b>

<b>风险等级</b> ${RISK^^}
<b>触发原因</b> $REASON

<b>命令</b>
<code>$CMD</code>

<b>请求ID</b> <code>$REQ_ID</code>
<b>结果</b> $status
<b>处理时间</b> $finished_at

<b>建议解读</b>
$advice"
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
