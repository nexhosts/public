#!/bin/bash
#
# Title: 1Password CLI Installer for Debian
# Description: This script automates the installation of the 1Password CLI
#              on Debian and other Debian-based Linux distributions.
# Author: Gemini
# Date: 2025-10-10

# --- Configuration ---
# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# Pipes fail if any command in the pipe fails.
set -o pipefail

# --- Pre-flight Checks ---

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
   echo "This script must be run as root. Please use 'sudo'." >&2
   exit 1
fi

# Check for curl
if ! command -v curl &> /dev/null; then
    echo "Error: curl is not installed. Installing it now..."
    apt-get update && apt-get install -y curl
fi

# Check for gpg
if ! command -v gpg &> /dev/null; then
    echo "Error: gpg is not installed. Installing it now..."
    apt-get update && apt-get install -y gpg
fi

echo "--- Starting 1Password CLI Installation ---"

# --- Installation Steps ---

# 1. Add the 1Password APT repository signing key
echo "[INFO] Adding 1Password APT repository GPG key..."
curl -fsSL https://downloads.1password.com/linux/keys/1password.asc | \
    gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg
# Set permissions for the key
chmod 644 /usr/share/keyrings/1password-archive-keyring.gpg

# 2. Add the 1Password APT repository
echo "[INFO] Adding the 1Password APT repository..."
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" | \
    tee /etc/apt/sources.list.d/1password.list > /dev/null

# 3. Update package lists
echo "[INFO] Updating package lists..."
apt-get update

# 4. Install 1Password CLI
echo "[INFO] Installing 1password-cli..."
apt-get install -y 1password-cli

# --- Verification ---
echo "[INFO] Verifying installation..."
if command -v op &> /dev/null; then
    echo "✅ 1Password CLI was installed successfully!"
    echo "   Version: $(op --version)"
    echo "   To get started, run 'op signin'"
else
    echo "❌ Installation failed. The 'op' command could not be found." >&2
    exit 1
fi

echo "--- Installation Complete ---"

exit 0
