#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/config.json"
APPROVAL="$HERE/request-approval.sh"
SOFT_ALERT="$HERE/request-soft-alert.sh"

USER_CONTEXT="${SAFEXEC_CONTEXT:-}"

get_confirmation_keywords() {
  local k
  k=$(jq -r '.contextAware.confirmationKeywords // "我已明确风险|I understand the risk"' "$CONFIG" 2>/dev/null || true)
  [[ -z "$k" || "$k" == "null" ]] && k="我已明确风险|I understand the risk"
  echo "$k"
}

detect_user_confirmation() {
  local context="$1"
  local keywords
  keywords=$(get_confirmation_keywords)
  echo "$context" | grep -qE "$keywords"
}

is_openclaw_key_config_touch() {
  local cmd="$1"
  # 仅在包含“写操作迹象”时触发软拦截提醒
  local write_hint='(sed[[:space:]]+-i|tee[[:space:]]|>[[:space:]]|>>[[:space:]]|cp[[:space:]]|mv[[:space:]]|cat[[:space:]].*>|jq[[:space:]].*>|perl[[:space:]].*-i|python[[:space:]].*open\()'
  if ! echo "$cmd" | grep -qE "$write_hint"; then
    return 1
  fi

  # 关键目标路径（可在 config.json 扩展）
  while IFS= read -r target; do
    [[ -z "$target" || "$target" == "null" ]] && continue
    if [[ "$cmd" == *"$target"* ]]; then
      return 0
    fi
  done < <(jq -r '.openclaw_key_targets[]? // empty' "$CONFIG")

  return 1
}

assess_risk() {
  local cmd="$1"
  local risk="low"
  local reason=""

  if [[ "$cmd" == *":(){:|:&};:"* ]] || [[ "$cmd" == *":(){ :|:& };:"* ]]; then
    risk="critical"; reason="Fork炸弹"
  elif echo "$cmd" | grep -qE 'rm[[:space:]]+-rf[[:space:]]+[\/~]'; then
    risk="critical"; reason="删除根目录或家目录文件"
  elif echo "$cmd" | grep -qE 'dd[[:space:]]+if='; then
    risk="critical"; reason="磁盘破坏命令"
  elif echo "$cmd" | grep -qE 'mkfs\.'; then
    risk="critical"; reason="格式化文件系统"
  elif echo "$cmd" | grep -qE '>[[:space:]]*/dev/sd[a-z]'; then
    risk="critical"; reason="直接写入磁盘"
  elif echo "$cmd" | grep -qE 'chmod[[:space:]]+777'; then
    risk="high"; reason="设置文件为全局可写"
  elif echo "$cmd" | grep -qE '>[[:space:]]*/(etc|boot|sys|root)/'; then
    risk="high"; reason="写入系统目录"
  elif echo "$cmd" | grep -qE '(curl|wget).*\|[[:space:]]*(bash|sh|python)'; then
    risk="high"; reason="管道下载到shell"
  elif echo "$cmd" | grep -qE 'sudo[[:space:]]+'; then
    risk="medium"; reason="使用特权执行"
  elif echo "$cmd" | grep -qE 'iptables|firewall-cmd|ufw'; then
    risk="medium"; reason="修改防火墙规则"
  fi

  echo "$risk|$reason"
}

CMD="$*"
assessment=$(assess_risk "$CMD")
RISK="${assessment%%|*}"
REASON="${assessment#*|}"

# context-aware downgrade (same spirit as safe-exec)
if [[ -n "$USER_CONTEXT" ]] && detect_user_confirmation "$USER_CONTEXT"; then
  if [[ "$RISK" == "critical" ]]; then
    RISK="medium"
    REASON="用户确认关键词触发降级（critical→medium）"
  elif [[ "$RISK" == "high" || "$RISK" == "medium" ]]; then
    old_risk="$RISK"
    RISK="low"
    REASON="用户确认关键词触发降级（${old_risk}→low）"
  fi
fi

if [[ "$RISK" == "low" ]]; then
  if is_openclaw_key_config_touch "$CMD"; then
    soft=$("$SOFT_ALERT" "$CMD")
    if [[ "$soft" == "blocked" ]]; then
      echo "[soft-guard] 🛑 已拦截本次关键配置修改" >&2
      exit 20
    fi
  fi
  eval "$CMD"
  exit $?
fi

decision=$("$APPROVAL" "$CMD" "$RISK" "$REASON")
case "$decision" in
  approved)
    echo "[approval] ✅ 批准（$RISK），执行：$CMD" >&2
    eval "$CMD"
    ;;
  rejected)
    echo "[approval] ❌ 被拒绝（$RISK）" >&2
    exit 10
    ;;
  timeout)
    echo "[approval] ⏳ 超时未批（$RISK）" >&2
    exit 11
    ;;
  *)
    echo "[approval] ❓ 未知状态" >&2
    exit 12
    ;;
esac
