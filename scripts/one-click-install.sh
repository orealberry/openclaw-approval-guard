#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/orealberry/openclaw-approval-guard.git"
WORKDIR="${TMPDIR:-/tmp}/openclaw-approval-guard-install-$$"

need_bin() { command -v "$1" >/dev/null 2>&1; }

echo "[1/5] Checking dependencies..."
if ! need_bin git; then
  echo "[error] git is required. Please install git first." >&2
  exit 1
fi
if ! need_bin curl; then
  echo "[error] curl is required. Please install curl first." >&2
  exit 1
fi

if ! need_bin cargo; then
  echo "[2/5] Rust not found. Installing rustup..."
  curl https://sh.rustup.rs -sSf | sh -s -- -y
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
else
  echo "[2/5] Rust already installed."
fi

# shellcheck disable=SC1091
[[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"

echo "[3/5] Cloning repository..."
rm -rf "$WORKDIR"
git clone --depth 1 "$REPO_URL" "$WORKDIR"

echo "[4/5] Building release binary..."
cd "$WORKDIR"
cargo build --release

echo "[5/5] Installing binary + running installer..."
mkdir -p "$HOME/.local/bin"
cp ./target/release/openclaw-approval-guard "$HOME/.local/bin/openclaw-approval-guard"
chmod +x "$HOME/.local/bin/openclaw-approval-guard"

if [[ -z "${APPROVAL_BOT_TOKEN:-}" ]]; then
  read -rsp "Enter APPROVAL_BOT_TOKEN: " APPROVAL_BOT_TOKEN
  echo
  export APPROVAL_BOT_TOKEN
fi

"$HOME/.local/bin/openclaw-approval-guard" install

echo ""
echo "✅ Done."
echo "If needed, add to PATH: export PATH=\"$HOME/.local/bin:$PATH\""
echo "Test command:"
echo "  openclaw-approval-guard run \"sudo id\""
