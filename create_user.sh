#!/usr/bin/env bash
# =============================================================================
#  create_user.sh  –  Create / fix dev user + password-less sudo (auto-repair)
#  Author:  Grok AI for nexhenry
# =============================================================================

set -euo pipefail

# --- Configuration ---
DEFAULT_USER="dev"
SUDOERS_MODE="0440"
# Assumes you want to copy the keys from the root user
SRC_KEYS="/root/.ssh/authorized_keys"

# --- Helpers ---
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

# --- Argument Parsing ---
TARGET_USER="$DEFAULT_USER"
if [[ "$1" == "--user" ]]; then
  [[ -z "$2" ]] && die "Usage: $0 --user <username>"
  TARGET_USER="$2"
fi

# --- 1. Root Check ---
if [[ $(id -u) -ne 0 ]]; then
  die "This script must be run as root."
fi

log "--- Configuring User: $TARGET_USER ---"

# --- 1b. Install sudo (which provides visudo) ---
if ! command -v visudo &>/dev/null; then
  log "Command 'visudo' not found. Installing 'sudo' package..."
  if command -v apt-get &>/dev/null; then
    apt-get update >/dev/null
    apt-get install -y sudo >/dev/null
  elif command -v yum &>/dev/null; then
    yum install -y sudo >/dev/null
  elif command -v dnf &>/dev/null; then
    dnf install -y sudo >/dev/null
  else
    die "Cannot find 'visudo' and don't know how to install 'sudo'. Please install it manually."
  fi
  log "Package 'sudo' installed."
fi

# --- 2. Create User (if needed) ---
if id "$TARGET_USER" &>/dev/null; then
  log "User '$TARGET_USER' already exists. Fixing permissions."
else
  log "Creating user '$TARGET_USER'..."
  # Create user, add to 'sudo' group, create home dir, set shell
  useradd -m -s /bin/bash -G sudo "$TARGET_USER" || die "Failed to create user."
fi

# --- 3. Remove Password ---
log "Removing password for '$TARGET_USER' (SSH-only login)..."
passwd -d "$TARGET_USER" >/dev/null

# --- 4. Copy SSH Keys ---
USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
DEST_DIR="$USER_HOME/.ssh"
DEST_KEYS="$DEST_DIR/authorized_keys"

if [[ ! -f "$SRC_KEYS" ]]; then
  log "WARNING: No $SRC_KEYS found. Skipping SSH key copy."
else
  log "Copying root's SSH keys to $DEST_KEYS..."
  mkdir -p "$DEST_DIR"
  cp "$SRC_KEYS" "$DEST_KEYS"
  
  log "Fixing SSH directory permissions..."
  chown -R "$TARGET_USER:$TARGET_USER" "$DEST_DIR"
  chmod 700 "$DEST_DIR"
  chmod 600 "$DEST_KEYS"
fi

# --- 5. Configure Sudo (The Safe Way) ---
SUDOERS_FILE="/etc/sudoers.d/$TARGET_USER"
SUDOERS_RULE="$TARGET_USER ALL=(ALL) NOPASSWD:ALL"
TEMP_FILE=$(mktemp)

# Ensure the /etc/sudoers.d directory exists
mkdir -p /etc/sudoers.d

log "Preparing sudoers rule in temporary file..."
printf '%s\n' "$SUDOERS_RULE" > "$TEMP_FILE"
chmod "$SUDOERS_MODE" "$TEMP_FILE"

log "Validating new sudoers rule..."
if visudo -c -f "$TEMP_FILE"; then
  log "Rule is valid. Installing to $SUDOERS_FILE..."
  # Move the valid file into place
  mv "$TEMP_FILE" "$SUDOERS_FILE"
  chown root:root "$SUDOERS_FILE"
else
  # Clean up the bad temp file
  rm -f "$TEMP_FILE"
  die "Generated sudoers rule FAILED syntax check. No changes made."
fi

log "--- Success! ---"
log "User '$TARGET_USER' is configured."
log "Home: $USER_HOME"
log "Sudo: Password-less"