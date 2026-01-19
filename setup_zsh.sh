#!/usr/bin/env bash
# =============================================================================
# setup_zsh.sh – Modular Zsh + Powerlevel10k installer (no external config)
# Author : nexhenry
# Version: 1.6.6 (Robust OMZ check)
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# 1. DEFAULT SETTINGS (edit here if you need to change anything)
# --------------------------------------------------------------------------- #
ZSH_GLOBAL_CUSTOM="/etc/zsh/custom"
P10K_GLOBAL_CONFIG="/etc/zsh/.p10k.zsh"
P10K_REMOTE_URL="https://raw.githubusercontent.com/nexhosts/public/main/.p10k.zsh"
OHMYZSH_INSTALL_URL="https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh"
MIN_UID=1000
# --> EDIT THIS LIST <-- to match users that actually exist on your system.
TARGET_USERS=("root" "debian" "ubuntu" "dev")
# ---------------------------------------------------------------------------

# --------------------------------------------------------------------------- #
# 2. LOGGING (Format updated to [LEVEL])
# --------------------------------------------------------------------------- #
readonly C_INFO="\033[1;32m" C_WARN="\033[1;33m" C_ERROR="\033[1;31m" C_RESET="\03S[0m"
log() { local color=$1; local level=$2; shift 2; echo -e "${color}[${level}]${C_RESET} $*"; }
log_info()  { log "$C_INFO"  "INFO"  "$@"; }
log_warn()  { log "$C_WARN"  "WARN"  "$@"; }
log_error() { log "$C_ERROR" "ERROR" "$@"; }
# ---------------------------------------------------------------------------

# --------------------------------------------------------------------------- #
# 3. UTILITIES
# --------------------------------------------------------------------------- #
is_root()   { [[ $EUID -eq 0 ]]; }
run_cmd()   { is_root && "$@" || sudo "$@"; }

run_as_user() {
    local user=$1; shift
    if is_root; then
        su -s /bin/sh - "$user" -c "$*"
    else
        sudo -u "$user" /bin/sh -c "$*"
    fi
}

package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

array_contains() {
    local seeking=$1; shift
    for element; do
        [[ "$element" == "$seeking" ]] && return 0
    done
    return 1
}
# ---------------------------------------------------------------------------

# --------------------------------------------------------------------------- #
# 4. SYSTEM PREPARATION
# --------------------------------------------------------------------------- #
install_dependencies() {
    log_info "Updating package index..."
    export DEBIAN_FRONTEND=noninteractive
    run_cmd apt-get update -qq

    local -a pkgs=(zsh git curl ca-certificates jq)
    for p in "${pkgs[@]}"; do
        if package_installed "$p"; then
            log_info "$p already installed"
        else
            log_info "Installing $p..."
            run_cmd apt-get install -yqq "$p"
        fi
    done
}

prepare_global_dir() {
    log_info "Creating global custom directory: $ZSH_GLOBAL_CUSTOM"
    run_cmd mkdir -p "$ZSH_GLOBAL_CUSTOM"
    run_cmd chmod 755 "$ZSH_GLOBAL_CUSTOM"
}

# --------------------------------------------------------------------------- #
# 5. GLOBAL PLUGINS / THEME
# --------------------------------------------------------------------------- #
declare -A REPOS=(
    [zsh-autosuggestions]="https://github.com/zsh-users/zsh-autosuggestions"
    [zsh-syntax-highlighting]="https://github.com/zsh-users/zsh-syntax-highlighting"
    [powerlevel10k]="https://github.com/romkatv/powerlevel10k"
)

clone_global_repo() {
    local name=$1 url=$2
    local dest="$ZSH_GLOBAL_CUSTOM/$name"
    [[ -d "$dest/.git" ]] && { log_info "$name already cloned"; return 0; }
    log_info "Cloning $name..."
    run_cmd git clone --quiet --depth 1 "$url" "$dest"
}

install_global_plugins() {
    log_info "Cloning/updating global plugins and theme..."
    for name in "${!REPOS[@]}"; do clone_global_repo "$name" "${REPOS[$name]}" & done
    wait
}

download_p10k_config() {
    [[ -f "$P10K_GLOBAL_CONFIG" ]] && { log_info "Global Powerlevel10k config already present"; return 0; }
    log_info "Downloading global Powerlevel10k configuration..."
    run_cmd curl -fsSL "$P10K_REMOTE_URL" -o "$P10K_GLOBAL_CONFIG"
    run_cmd chmod 644 "$P10K_GLOBAL_CONFIG"
}

# --------------------------------------------------------------------------- #
# 6. PER-USER CONFIGURATION
# --------------------------------------------------------------------------- #

# --FUNCTION IMPROVED--
install_ohmyzsh() {
    local user=$1 homedir=$2
    local ohmyzsh_dir="$homedir/.oh-my-zsh"
    
    # **IMPROVEMENT**: Check for the actual script file, not just the directory.
    # This detects broken/incomplete installations.
    [[ -f "$ohmyzsh_dir/oh-my-zsh.sh" ]] && { 
        log_info "Oh My Zsh already installed for $user"
        return 0 
    }

    log_info "Installing/Repairing Oh My Zsh for $user..."
    
    # This command will re-run and fix a broken install
    local install_cmd="ZSH='$ohmyzsh_dir' RUNZSH=no CHSH=no sh -c \"\$(curl -fsSL $OHMYZSH_INSTALL_URL)\" --unattended"
    if ! run_as_user "$user" "$install_cmd"; then
        log_error "Failed to install Oh My Zsh for $user"
        return 1
    fi
    return 0
}

link_p10k_theme() {
    local user=$1 homedir=$2
    local theme_dir="$homedir/.oh-my-zsh/custom/themes"
    run_as_user "$user" "mkdir -p '$theme_dir'"
    run_as_user "$user" "ln -sfn '$ZSH_GLOBAL_CUSTOM/powerlevel10k' '$theme_dir/powerlevel10k'"
    log_info "Linked Powerlevel10k theme for $user"
}

write_zshrc() {
    local user=$1 homedir=$2
    local zshrc="$homedir/.zshrc"

    cat <<'EOF' | run_cmd tee "$zshrc" > /dev/null
# ==== AUTOMATICALLY MANAGED – DO NOT EDIT ====
export ZSH="$HOME/.oh-my-zsh"

# Powerlevel10k config (user-local overrides global)
[[ -r "$HOME/.p10k.zsh" ]] && source "$HOME/.p10k.zsh" || \
  { [[ -r "%GLOBAL_P10K%" ]] && cp "%GLOBAL_P10K%" "$HOME/.p10k.zsh" && source "$HOME/.p10k.zsh"; }

ZSH_THEME="powerlevel10k/powerlevel10k"
POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD=true

plugins=(git)
source "$ZSH/oh-my-zsh.sh"

# Global custom plugins
[[ -s "%GLOBAL_CUSTOM%/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]] && \
    source "%GLOBAL_CUSTOM%/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
[[ -s "%GLOBAL_CUSTOM%/zsh-autosuggestions/zsh-autosuggestions.zsh" ]] && \
    source "%GLOBAL_CUSTOM%/zsh-autosuggestions/zsh-autosuggestions.zsh"

# --- ssh-agent config ---
# Define the path to a specific key you want to load
# Using a modern key type like ed25519 is recommended
SSH_KEY_PATH="$HOME/.ssh/sshkey"

# Start ssh-agent if it's not already running
if [ -z "$SSH_AUTH_SOCK" ]; then
   # Start the agent and capture its output
   eval "$(ssh-agent -s)" > /dev/null
fi

# Add your SSH key if no identities are loaded
# `ssh-add -l` returns 1 if the agent has no keys
if ! ssh-add -l > /dev/null; then
  # Check if the specific key file exists before trying to add it
  if [ -f "$SSH_KEY_PATH" ]; then
    # Add the key, suppressing the "Identity added" message
    ssh-add "$SSH_KEY_PATH" > /dev/null
  fi
fi

# Handy aliases
alias ll='ls -alF'
alias la='ls -A'
alias md='mkdir -p'
alias apt='sudo apt'
alias python='python3'
alias env_create='bash $HOME/utils/bash/env_create.sh'
alias repo_init='bash $HOME/utils/bash/repo_init.sh'
EOF
    # --- END OF HEREDOC ---

    run_cmd sed -i \
        -e "s|%GLOBAL_P10K%|$P10K_GLOBAL_CONFIG|g" \
        -e "s|%GLOBAL_CUSTOM%|$ZSH_GLOBAL_CUSTOM|g" \
        "$zshrc"

    if [[ "$user" == "root" ]]; then
        run_cmd sed -i "/^alias apt='sudo apt'$/d" "$zshrc"
    fi

    run_cmd chown "$user:$user" "$zshrc"
    log_info "Wrote .zshrc for $user"
}

change_shell() {
    local user=$1
    local zsh_path
    zsh_path=$(command -v zsh) || { log_error "zsh binary not found"; return 1; }

    if ! grep -q "^${zsh_path}$" /etc/shells; then
        log_info "Adding $zsh_path to /etc/shells..."
        echo "$zsh_path" | run_cmd tee -a /etc/shells > /dev/null
    fi

    [[ "$(getent passwd "$user" | cut -d: -f7)" == "$zsh_path" ]] && {
        log_info "Shell already zsh for $user"
        return 0
    }

    log_info "Changing shell to zsh for $user..."
    if ! run_cmd chsh -s "$zsh_path" "$user"; then
        log_warn "chsh command failed for $user."
        log_warn "This can happen with system users or in minimal containers."
        return 1
    fi
}

fix_ownership() {
    local user=$1 homedir=$2
    run_cmd chown -R "$user:$user" "$homedir/.oh-my-zsh" "$homedir/.zshrc" 2>/dev/null || true
    [[ -f "$homedir/.p10k.zsh" ]] && run_cmd chown "$user:$user" "$homedir/.p10k.zsh" 2>/dev/null || true
    log_info "Ownership corrected for $user"
}

process_user() {
    local username=$1 uid=$2 homedir=$3
    log_info "Processing user: $username (uid=$uid, home=$homedir)"

    if ! install_ohmyzsh "$username" "$homedir"; then
        log_warn "Oh My Zsh installation failed. Cannot proceed with setup for $username."
        return 1 
    fi
    
    link_p10k_theme   "$username" "$homedir"
    write_zshrc       "$username" "$homedir"
    change_shell      "$username"
    fix_ownership     "$username" "$homedir"
}

# --------------------------------------------------------------------------- #
# 7. USER SELECTION
# --------------------------------------------------------------------------- #
process_one_user() {
    local user=$1

    local line
    line=$(getent passwd "$user") || { log_warn "No passwd entry for $user – skipping"; return 1; }

    IFS=: read -r _ _ uid _ _ homedir _ <<< "$line"

    [[ -z "$homedir" || ! -d "$homedir" ]] && { log_warn "Invalid home directory for $user – skipping"; return 1; }

    process_user "$user" "$uid" "$homedir"
    return 0
}

run_user_setup() {
    local any_error=0

    # 1. Explicit users
    for u in "${TARGET_USERS[@]}"; do
        [[ -n "$u" ]] && process_one_user "$u" || any_error=1
    done

    # 2. Auto-detect normal users (uid >= MIN_UID)
    while IFS=: read -r name _ uid _ _ home _; do
        [[ -z "$name" || "$uid" -lt "$MIN_UID" ]] && continue
        array_contains "$name" "${TARGET_USERS[@]}" && continue
        [[ -d "$home" ]] && process_one_user "$name" || any_error=1
    done < <(getent passwd)

    return "$any_error"
}

# --------------------------------------------------------------------------- #
# 8. MAIN
# --------------------------------------------------------------------------- #
main() {
    log_info "Starting Zsh + Powerlevel10k setup..."

    install_dependencies
    prepare_global_dir
    install_global_plugins
    download_p10k_config

    local any_error=0
    run_user_setup || any_error=1

    log_info "Zsh setup completed successfully!"
    (( any_error )) && log_warn "Some non-critical steps failed (see above)."
    return 0
}

# --------------------------------------------------------------------------- #
# 9. ENTRY POINT
# --------------------------------------------------------------------------- #
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"