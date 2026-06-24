#!/usr/bin/env bash
# =============================================================================
#  create_user.sh
#  Create a user with password-less sudo, SSH keys, and cloned zsh/oh-my-zsh setup.
#
#  Local (as root):
#    sudo ./create_user.sh --user linewise
#
#  Remote:
#    ./create_user.sh --user linewise --host debian@10.10.10.20
# =============================================================================

set -euo pipefail

DEFAULT_USER="dev"
SUDOERS_MODE="0440"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

usage() {
    cat <<EOF
Usage: $0 --user <username> [OPTIONS]

Create a user with password-less sudo, SSH authorized_keys, and zsh/oh-my-zsh config
cloned from an existing account on the target machine.

Required:
  --user <name>           User to create

Optional:
  --host [login@]host     Run on a remote host via SSH (e.g. debian@10.10.10.20)
  --from-user <name>      Template account for SSH keys and zsh config
                          (default: SSH login user on remote, else debian/root locally)
  --ssh-key <path>        SSH private key for remote connection
  -h, --help              Show this help

Examples:
  sudo $0 --user linewise
  $0 --user linewise --host debian@10.10.10.20
  $0 --user linewise --host 10.10.10.20 --from-user debian --ssh-key ~/.ssh/nexhenry
EOF
    exit 1
}

resolve_user_home() {
    getent passwd "$1" 2>/dev/null | cut -d: -f6 || true
}

resolve_ssh_key() {
    local spec="${1:-}"
    if [[ -n "$spec" ]]; then
        if [[ -f "$spec" ]]; then
            echo "$spec"
            return 0
        fi
        if [[ -f "${HOME}/.ssh/${spec}" ]]; then
            echo "${HOME}/.ssh/${spec}"
            return 0
        fi
        die "SSH key not found: $spec"
    fi
    local candidate
    for candidate in "${HOME}/.ssh/sshkey" "${HOME}/.ssh/id_ed25519" "${HOME}/.ssh/id_rsa"; do
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    echo ""
}

parse_host_spec() {
    local spec="$1"
    if [[ "$spec" == *@* ]]; then
        REMOTE_LOGIN="${spec%%@*}"
        REMOTE_HOST="${spec#*@}"
    else
        REMOTE_HOST="$spec"
        REMOTE_LOGIN=""
    fi
    [[ -n "$REMOTE_HOST" ]] || die "Invalid --host value: $spec"
}

read -r -d '' SETUP_SCRIPT <<'SETUP' || true
set -euo pipefail

TARGET_USER="$1"
TEMPLATE_USER="$2"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

SUDOERS_MODE="0440"

resolve_user_home() {
    getent passwd "$1" 2>/dev/null | cut -d: -f6 || true
}

ensure_sudo_package() {
    if command -v visudo &>/dev/null; then
        return 0
    fi
    log "Installing sudo package (visudo not found)..."
    if command -v apt-get &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq sudo
    elif command -v dnf &>/dev/null; then
        dnf install -y sudo
    elif command -v yum &>/dev/null; then
        yum install -y sudo
    else
        die "Cannot install sudo automatically."
    fi
}

ensure_zsh_package() {
    command -v zsh &>/dev/null && return 0
    log "Installing zsh..."
    if command -v apt-get &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y -qq zsh
    elif command -v dnf &>/dev/null; then
        dnf install -y zsh
    elif command -v yum &>/dev/null; then
        yum install -y zsh
    else
        die "zsh is required but could not be installed."
    fi
}

default_shell() {
    local shell_path="/bin/bash"
    if command -v zsh &>/dev/null; then
        shell_path="$(command -v zsh)"
    fi
    echo "$shell_path"
}

ensure_shell_registered() {
    local shell_path="$1"
    [[ -f "$shell_path" ]] || die "Shell not found: $shell_path"
    if ! grep -qxF "$shell_path" /etc/shells 2>/dev/null; then
        log "Adding $shell_path to /etc/shells"
        echo "$shell_path" >> /etc/shells
    fi
}

create_or_fix_user() {
    local shell_path
    shell_path="$(default_shell)"
    ensure_shell_registered "$shell_path"

    if id "$TARGET_USER" &>/dev/null; then
        log "User '$TARGET_USER' already exists; updating shell and group membership."
        usermod -s "$shell_path" "$TARGET_USER" 2>/dev/null || true
    else
        log "Creating user '$TARGET_USER' (shell: $shell_path)..."
        local useradd_args=(-m -s "$shell_path")
        if getent group sudo &>/dev/null; then
            useradd_args+=(-G sudo)
        fi
        useradd "${useradd_args[@]}" "$TARGET_USER" || die "Failed to create user '$TARGET_USER'."
    fi

    if getent group sudo &>/dev/null && ! id -nG "$TARGET_USER" | grep -qw sudo; then
        log "Adding '$TARGET_USER' to sudo group..."
        usermod -aG sudo "$TARGET_USER"
    fi
}

remove_password() {
    log "Removing password for '$TARGET_USER' (SSH-only login)..."
    passwd -d "$TARGET_USER" >/dev/null 2>&1 || true
}

copy_ssh_keys() {
    local template_home target_home src_keys dest_dir dest_keys
    template_home="$(resolve_user_home "$TEMPLATE_USER")"
    target_home="$(resolve_user_home "$TARGET_USER")"
    [[ -n "$target_home" ]] || die "Could not resolve home for '$TARGET_USER'."

    src_keys="${template_home}/.ssh/authorized_keys"
    dest_dir="${target_home}/.ssh"
    dest_keys="${dest_dir}/authorized_keys"

    if [[ ! -f "$src_keys" ]]; then
        log "WARNING: No authorized_keys at ${src_keys}; skipping SSH key copy."
        return 0
    fi

    log "Copying SSH keys from '${TEMPLATE_USER}' to '${TARGET_USER}'..."
    mkdir -p "$dest_dir"
    cp "$src_keys" "$dest_keys"
    chown -R "${TARGET_USER}:${TARGET_USER}" "$dest_dir"
    chmod 700 "$dest_dir"
    chmod 600 "$dest_keys"
}

configure_passwordless_sudo() {
    local sudoers_file="/etc/sudoers.d/${TARGET_USER}"
    local temp_file
    temp_file="$(mktemp)"

    mkdir -p /etc/sudoers.d
    printf '%s\n' "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL" > "$temp_file"
    chmod "$SUDOERS_MODE" "$temp_file"

    log "Validating sudoers rule..."
    if visudo -c -f "$temp_file"; then
        mv "$temp_file" "$sudoers_file"
        chown root:root "$sudoers_file"
        chmod "$SUDOERS_MODE" "$sudoers_file"
    else
        rm -f "$temp_file"
        die "Generated sudoers rule failed syntax check."
    fi
}

clone_zsh_config() {
    local template_home target_home
    template_home="$(resolve_user_home "$TEMPLATE_USER")"
    target_home="$(resolve_user_home "$TARGET_USER")"

    [[ -n "$template_home" && -d "$template_home" ]] || die "Template home missing for '$TEMPLATE_USER'."
    [[ -n "$target_home" && -d "$target_home" ]] || die "Target home missing for '$TARGET_USER'."

    if [[ ! -f "${template_home}/.zshrc" ]]; then
        log "WARNING: ${template_home}/.zshrc not found; skipping zsh clone."
        return 0
    fi

    ensure_zsh_package
    local zsh_path
    zsh_path="$(command -v zsh)"
    ensure_shell_registered "$zsh_path"

    log "Cloning zsh config from '${TEMPLATE_USER}' to '${TARGET_USER}'..."

    if [[ -d "${template_home}/.oh-my-zsh" ]]; then
        rm -rf "${target_home}/.oh-my-zsh"
        cp -a "${template_home}/.oh-my-zsh" "${target_home}/.oh-my-zsh"
        log "Copied .oh-my-zsh"
    else
        log "WARNING: ${template_home}/.oh-my-zsh not found; copied .zshrc only."
    fi

    cp -a "${template_home}/.zshrc" "${target_home}/.zshrc"

    if [[ -f "${template_home}/.p10k.zsh" ]]; then
        cp -a "${template_home}/.p10k.zsh" "${target_home}/.p10k.zsh"
        log "Copied .p10k.zsh"
    fi

    chown -R "${TARGET_USER}:${TARGET_USER}" "${target_home}/.zshrc"
    [[ -d "${target_home}/.oh-my-zsh" ]] && chown -R "${TARGET_USER}:${TARGET_USER}" "${target_home}/.oh-my-zsh"
    [[ -f "${target_home}/.p10k.zsh" ]] && chown "${TARGET_USER}:${TARGET_USER}" "${target_home}/.p10k.zsh"

    chmod 644 "${target_home}/.zshrc"
    [[ -f "${target_home}/.p10k.zsh" ]] && chmod 644 "${target_home}/.p10k.zsh"

    if [[ "$(getent passwd "$TARGET_USER" | cut -d: -f7)" != "$zsh_path" ]]; then
        log "Setting login shell to zsh for '$TARGET_USER'..."
        chsh -s "$zsh_path" "$TARGET_USER"
    fi

    log "Zsh theme/plugins from template preserved (see ${target_home}/.zshrc)."
}

[[ $(id -u) -eq 0 ]] || die "Setup script must run as root."

log "--- Configuring user: ${TARGET_USER} (template: ${TEMPLATE_USER}) ---"
ensure_sudo_package
create_or_fix_user
remove_password
copy_ssh_keys
configure_passwordless_sudo
clone_zsh_config

TARGET_HOME="$(resolve_user_home "$TARGET_USER")"
log "--- Success ---"
log "User: ${TARGET_USER}"
log "Home: ${TARGET_HOME}"
log "Sudo: password-less"
log "Shell: $(getent passwd "$TARGET_USER" | cut -d: -f7)"
SETUP

run_local_setup() {
    local target_user="$1"
    local template_user="$2"

    if [[ $(id -u) -ne 0 ]]; then
        die "Local mode must run as root (use: sudo $0 ...)."
    fi

    printf '%s' "$SETUP_SCRIPT" | bash -s -- "$target_user" "$template_user"
}

run_remote_setup() {
    local target_user="$1"
    local template_user="$2"
    local ssh_login="$3"
    local ssh_host="$4"
    local ssh_key="$5"

    local ssh_opts=(
        -o BatchMode=yes
        -o ConnectTimeout=15
        -o StrictHostKeyChecking=accept-new
    )
    [[ -n "$ssh_key" ]] && ssh_opts+=(-i "$ssh_key" -o IdentitiesOnly=yes)

    log "Running remote setup on ${ssh_login}@${ssh_host} for user '${target_user}'..."

    local output rc=0
    set +e
    output=$(printf '%s' "$SETUP_SCRIPT" | ssh "${ssh_opts[@]}" "${ssh_login}@${ssh_host}" \
        "sudo bash -s -- $(printf '%q' "$target_user") $(printf '%q' "$template_user")" 2>&1)
    rc=$?
    set -e

    if [[ $rc -ne 0 ]]; then
        die "Remote setup failed on ${ssh_login}@${ssh_host} (exit ${rc}).${output:+
$output}"
    fi

    echo "$output"
}

# --- Argument parsing ---
TARGET_USER=""
REMOTE_HOST=""
REMOTE_LOGIN=""
FROM_USER=""
SSH_KEY_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            TARGET_USER="${2:-}"
            shift 2
            ;;
        --host)
            parse_host_spec "${2:-}"
            shift 2
            ;;
        --from-user)
            FROM_USER="${2:-}"
            shift 2
            ;;
        --ssh-key)
            SSH_KEY_ARG="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            die "Unknown argument: $1 (try --help)"
            ;;
    esac
done

TARGET_USER="${TARGET_USER:-$DEFAULT_USER}"

if [[ -n "$REMOTE_HOST" ]]; then
    REMOTE_LOGIN="${REMOTE_LOGIN:-${USER:-$(id -un)}}"
    TEMPLATE_USER="${FROM_USER:-$REMOTE_LOGIN}"
    SSH_KEY="$(resolve_ssh_key "$SSH_KEY_ARG")"
    log "Target: ${TARGET_USER} on ${REMOTE_LOGIN}@${REMOTE_HOST} (template: ${TEMPLATE_USER})"
    [[ -n "$SSH_KEY" ]] && log "SSH key: ${SSH_KEY}"
    run_remote_setup "$TARGET_USER" "$TEMPLATE_USER" "$REMOTE_LOGIN" "$REMOTE_HOST" "$SSH_KEY"
else
    if [[ -n "$FROM_USER" ]]; then
        TEMPLATE_USER="$FROM_USER"
    elif [[ -n "$(resolve_user_home debian)" && -f "$(resolve_user_home debian)/.zshrc" ]]; then
        TEMPLATE_USER="debian"
    else
        TEMPLATE_USER="root"
    fi
    log "Target: ${TARGET_USER} locally (template: ${TEMPLATE_USER})"
    run_local_setup "$TARGET_USER" "$TEMPLATE_USER"
fi
