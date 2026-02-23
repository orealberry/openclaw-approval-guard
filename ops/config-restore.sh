#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT="/root/.openclaw/workspace/.safety/config-backups"
TARGET="${1:-latest}"

if [[ "$TARGET" == "latest" ]]; then
  if [[ ! -L "$BACKUP_ROOT/latest" && ! -d "$BACKUP_ROOT/latest" ]]; then
    echo "No latest backup found at $BACKUP_ROOT/latest" >&2
    exit 1
  fi
  SRC_DIR="$(readlink -f "$BACKUP_ROOT/latest")"
else
  SRC_DIR="$BACKUP_ROOT/$TARGET"
fi

ARCHIVE="$SRC_DIR/config-backup.tar.gz"
CHECKSUM="$SRC_DIR/config-backup.sha256"

if [[ ! -f "$ARCHIVE" ]]; then
  echo "Backup archive not found: $ARCHIVE" >&2
  exit 1
fi

if [[ -f "$CHECKSUM" ]]; then
  (cd "$SRC_DIR" && sha256sum -c "$(basename "$CHECKSUM")")
fi

# 安全确认
if [[ "${2:-}" != "--yes" ]]; then
  echo "About to restore from: $SRC_DIR"
  echo "Run with --yes to proceed."
  exit 2
fi

# 恢复到根路径
tar -xzf "$ARCHIVE" -P

echo "Restore completed from: $SRC_DIR"
