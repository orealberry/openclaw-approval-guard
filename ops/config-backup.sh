#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT="/root/.openclaw/workspace/.safety/config-backups"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
DEST_DIR="$BACKUP_ROOT/$STAMP"
mkdir -p "$DEST_DIR"

# 关键配置（按需可扩展）
FILES=(
  "/root/.openclaw/openclaw.json"
  "/root/.openclaw/openclaw.json.bak"
  "/root/.openclaw/cron/jobs.json"
  "/root/.openclaw/agents/main/agent/auth-profiles.json"
  "/root/.openclaw/agents/main/agent/auth.json"
  "/root/.config/systemd/user/openclaw-gateway.service"
)

MANIFEST="$DEST_DIR/manifest.txt"
: > "$MANIFEST"

for f in "${FILES[@]}"; do
  if [[ -f "$f" ]]; then
    echo "$f" >> "$MANIFEST"
  fi
done

if [[ ! -s "$MANIFEST" ]]; then
  echo "No files found to back up." >&2
  exit 1
fi

# 使用 tar 保留原始绝对路径结构（恢复更稳）
ARCHIVE="$DEST_DIR/config-backup.tar.gz"
tar --absolute-names -czf "$ARCHIVE" -T "$MANIFEST"
sha256sum "$ARCHIVE" > "$DEST_DIR/config-backup.sha256"

# 记录最近一次
ln -sfn "$DEST_DIR" "$BACKUP_ROOT/latest"

echo "Backup created: $ARCHIVE"
