#!/usr/bin/env bash
set -euo pipefail

RUNTIME_DIR="$HOME/.openclaw/approval-guard"
PLUGIN_DIR="$HOME/.openclaw/extensions/approval-guard-full"

rm -rf "$RUNTIME_DIR" "$PLUGIN_DIR"
openclaw gateway restart >/dev/null 2>&1 || true

echo "[done] approval guard removed"
