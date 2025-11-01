#!/bin/bash

set -e

# === FUNCTIONS ===

usage() {
    echo "Usage: $0 --id <id>"
    exit 1
}

# Parse arguments
ID=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --id)
            ID="$2"
            shift 2
            ;;
        *)
            echo "❌ Unknown argument: $1"
            usage
            ;;
    esac
done

if [ -z "$ID" ]; then
    echo "❌ Error: --id is required."
    usage
fi

# === CONFIG BASED ON ID ===

SSH_DIR="$HOME/.ssh"
PUBKEY_FILE="$SSH_DIR/${ID}.pub"
PRIVKEY_FILE="$SSH_DIR/${ID}"
ZSHRC_FILE="$HOME/.zshrc"

PUBKEY_OP_REF="op://dev/sshkey_${ID}/public key"
PRIVKEY_OP_REF="op://dev/sshkey_${ID}/private key"
GIT_USER_NAME_OP_REF="op://dev/github_${ID}/display_name"
GIT_USER_EMAIL_OP_REF="op://dev/github_${ID}/email"
GIT_DEFAULT_BRANCH="main"

SSH_AGENT_MARKER="# Configure ssh-agent (added by git_ssh_setup.sh)"
SSH_AGENT_CONFIG=$(cat <<'EOF'
# Configure ssh-agent (added by git_setup.sh)
if [ -z "$SSH_AUTH_SOCK" ]; then
  eval "$(ssh-agent -s)" > /dev/null
fi
# --- End ssh-agent config ---
EOF
)

# === MAIN LOGIC ===

echo "📋 Starting Git and SSH setup for ID '$ID'..."

# Ensure ~/.ssh exists
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# --- Fetch SSH Keys ---

echo "🔑 Fetching public key..."
op read "$PUBKEY_OP_REF" > "$PUBKEY_FILE"
chmod 644 "$PUBKEY_FILE"
echo "✅ Public key saved to $PUBKEY_FILE"

echo "🔑 Fetching private key..."
op read "$PRIVKEY_OP_REF" > "$PRIVKEY_FILE"
chmod 600 "$PRIVKEY_FILE"
echo "✅ Private key saved to $PRIVKEY_FILE"

# --- Setup ssh-agent in .zshrc if not already configured ---

if grep -Fxq "$SSH_AGENT_MARKER" "$ZSHRC_FILE"; then
    echo "✅ ssh-agent already configured in $ZSHRC_FILE. Skipping addition."
else
    echo "➕ Adding ssh-agent configuration to $ZSHRC_FILE..."
    echo -e "\n$SSH_AGENT_CONFIG" >> "$ZSHRC_FILE"
    echo "✅ ssh-agent configuration added. (New sessions will auto-start ssh-agent)"
fi

# --- Add private key to currently running ssh-agent (if possible) ---

if [[ -n "$SSH_AUTH_SOCK" ]] && command -v ssh-add &> /dev/null; then
    echo "🛡️ Adding key to currently running ssh-agent..."
    ssh-add "$PRIVKEY_FILE" || echo "⚠️ Warning: Failed to add key to ssh-agent (may require manual ssh-add later)"
else
    echo "⚠️ ssh-agent not running or ssh-add missing. Will activate automatically on next shell session."
fi

# --- Git Configuration ---

echo "⚙️ Configuring global Git settings..."

GIT_USER_NAME=$(op read "$GIT_USER_NAME_OP_REF")
GIT_USER_EMAIL=$(op read "$GIT_USER_EMAIL_OP_REF")

if [[ -z "$GIT_USER_NAME" || -z "$GIT_USER_EMAIL" ]]; then
    echo "❌ Error: Failed to retrieve Git user.name or user.email from 1Password."
    exit 1
fi

git config --global user.name "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"
git config --global init.defaultBranch "$GIT_DEFAULT_BRANCH"

echo "✅ Git user.name set to: $GIT_USER_NAME"
echo "✅ Git user.email set to: $GIT_USER_EMAIL"
echo "✅ Git default branch set to: $GIT_DEFAULT_BRANCH"

# --- Final Messages ---

echo ""
echo "🎉 Setup complete!"
echo "✅ SSH keys are ready in ~/.ssh/"
echo "✅ Git global config is set."
echo ""
echo "👉 Remember to add your public key ($PUBKEY_FILE) to GitHub or GitLab."
echo "👉 If using a custom SSH config, you can add:"
echo ""
echo "Host github.com-${ID}"
echo "  HostName github.com"
echo "  User git"
echo "  IdentityFile $PRIVKEY_FILE"
echo "  IdentitiesOnly yes"
echo ""
echo "Start a new shell session to ensure ssh-agent auto-starts."
echo ""

exit 0
