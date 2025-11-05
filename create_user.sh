#!/usr/bin/env bash
# =====================================================
# Create or configure a development user with SSH + sudo
# Works when executed as root or non-root user
# Usage: ./create_dev_user.sh [--user username]
# Default user: dev
# =====================================================

set -euo pipefail

USER_NAME="dev"
RUN_SUDO=""

# --- Detect if root ---
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo &>/dev/null; then
    RUN_SUDO="sudo"
  else
    echo "❌ This script must be run as root or with sudo privileges."
    exit 1
  fi
fi

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      USER_NAME="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--user username]"
      exit 1
      ;;
  esac
done

echo "👤 Setting up user: $USER_NAME"

# --- Create user if not exists ---
if id "$USER_NAME" &>/dev/null; then
  echo "✅ User '$USER_NAME' already exists."
else
  echo "➕ Creating user '$USER_NAME'..."
  $RUN_SUDO useradd -m -s /bin/bash -G sudo "$USER_NAME"
fi

# --- Remove password (SSH-only login) ---
$RUN_SUDO passwd -d "$USER_NAME" &>/dev/null || true

# --- Copy SSH authorized_keys ---
SRC_AUTH_KEYS="$HOME/.ssh/authorized_keys"
DEST_DIR="/home/$USER_NAME/.ssh"
DEST_AUTH_KEYS="$DEST_DIR/authorized_keys"

if [ -f "$SRC_AUTH_KEYS" ]; then
  echo "🔑 Copying SSH authorized_keys..."
  $RUN_SUDO mkdir -p "$DEST_DIR"
  $RUN_SUDO cp -f "$SRC_AUTH_KEYS" "$DEST_AUTH_KEYS"
  $RUN_SUDO chown -R "$USER_NAME:$USER_NAME" "$DEST_DIR"
  $RUN_SUDO chmod 700 "$DEST_DIR"
  $RUN_SUDO chmod 600 "$DEST_AUTH_KEYS"
else
  echo "⚠️  No $SRC_AUTH_KEYS found. Skipping SSH key copy."
fi

# --- Configure passwordless sudo ---
echo "🛠️  Configuring passwordless sudo..."
$RUN_SUDO mkdir -p /etc/sudoers.d
echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" | $RUN_SUDO tee "/etc/sudoers.d/$USER_NAME" >/dev/null
$RUN_SUDO chmod 440 "/etc/sudoers.d/$USER_NAME"

echo "✅ Setup complete for user '$USER_NAME'"
