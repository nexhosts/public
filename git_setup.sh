#!/bin/bash

set -euo pipefail

# === FUNCTIONS ===

usage() {
    cat <<EOF
Usage: $0 --git-user <id> [OPTIONS]

Configure Git identity and SSH keys from 1Password for local or remote hosts.
The --git-user value is the GitHub / 1Password ID (sshkey_<id>, github_<id>).

Required:
  --git-user <id>     GitHub / 1Password ID; also the target OS user and ~/.ssh/<id> key name
                      (--id is an alias for --git-user)

Optional:
  --host <host>       Remote host to configure (default: localhost)
  --user <user>       SSH login user for --host (default: current user)
  --ssh-key <ref>     Key for SSH to --host: local path or 1Password ID (default: ~/.ssh/sshkey)
  -h, --help          Show this help

Examples:
  # Local setup
  $0 --git-user nexhenry

  # Remote: login as debian, configure OS user nexhenry; SSH key from 1Password
  $0 --host 10.10.10.70 --user debian --git-user nexhenry --ssh-key nexhenry

  # Remote: SSH key from local file
  $0 --host 10.10.10.70 --user root --git-user nexhenry --ssh-key ~/.ssh/sshkey
EOF
    exit 1
}

log() { echo "$@"; }
log_ok() { echo "✅ $*"; }
log_err() { echo "❌ $*" >&2; }
log_warn() { echo "⚠️  $*" >&2; }

b64_encode() {
    printf '%s' "$1" | base64 -w0 2>/dev/null || printf '%s' "$1" | base64
}

GIT_KEY_PRIV_FILE=""
GIT_KEY_PUB_FILE=""
GIT_KEY_TEMP_DIR=""

cleanup_git_key_temp() {
    if [[ -n "$GIT_KEY_TEMP_DIR" && -d "$GIT_KEY_TEMP_DIR" ]]; then
        rm -rf "$GIT_KEY_TEMP_DIR"
        GIT_KEY_TEMP_DIR=""
    fi
}

load_git_key_material() {
    local id="$1"
    local priv="${HOME}/.ssh/${id}"
    local pub="${HOME}/.ssh/${id}.pub"

    GIT_KEY_PRIV_FILE=""
    GIT_KEY_PUB_FILE=""
    cleanup_git_key_temp

    if [[ -f "$priv" && -f "$pub" ]] && ssh-keygen -y -f "$priv" >/dev/null 2>&1; then
        GIT_KEY_PRIV_FILE="$priv"
        GIT_KEY_PUB_FILE="$pub"
        log "🔑 Using local SSH key material from ${priv}"
        return 0
    fi

    GIT_KEY_TEMP_DIR=$(mktemp -d)
    chmod 700 "$GIT_KEY_TEMP_DIR"
    if ! run_op_read "op://dev/sshkey_${id}/private key" > "${GIT_KEY_TEMP_DIR}/${id}"; then
        cleanup_git_key_temp
        return 1
    fi
    if ! run_op_read "op://dev/sshkey_${id}/public key" > "${GIT_KEY_TEMP_DIR}/${id}.pub"; then
        cleanup_git_key_temp
        return 1
    fi
    chmod 600 "${GIT_KEY_TEMP_DIR}/${id}"
    chmod 644 "${GIT_KEY_TEMP_DIR}/${id}.pub"
    GIT_KEY_PRIV_FILE="${GIT_KEY_TEMP_DIR}/${id}"
    GIT_KEY_PUB_FILE="${GIT_KEY_TEMP_DIR}/${id}.pub"
    validate_ssh_key_file "$GIT_KEY_PRIV_FILE" || { cleanup_git_key_temp; return 1; }
}

validate_ssh_key_file() {
    local key_file="$1"
    if ! ssh-keygen -y -f "$key_file" >/dev/null 2>&1; then
        log_err "SSH private key is invalid or corrupt: ${key_file}"
        return 1
    fi
}

agent_zsh_block_content() {
    local key_file="$1"
    local id="$2"
    cat <<EOF
# Configure ssh-agent for ${id} (added by git_setup.sh)
if [ -z "\${SSH_AUTH_SOCK:-}" ]; then
  eval "\$(ssh-agent -s)" >/dev/null
fi
_git_setup_key="${key_file}"
if [ -f "\$_git_setup_key" ]; then
  _git_setup_fp=\$(ssh-keygen -lf "\$_git_setup_key" 2>/dev/null | awk '{print \$2}')
  if [ -z "\$_git_setup_fp" ] || ! ssh-add -l 2>/dev/null | grep -qF "\$_git_setup_fp"; then
    ssh-add "\$_git_setup_key" >/dev/null 2>&1 || true
  fi
fi
unset _git_setup_key _git_setup_fp
# --- End ssh-agent config for ${id} ---
EOF
}

install_zshrc_agent_block() {
    local key_file="$1"
    local id="$2"
    local zshrc="$3"
    local marker="# Configure ssh-agent for ${id} (added by git_setup.sh)"
    local end_marker="# --- End ssh-agent config for ${id} ---"
    local block tmp

    [[ -f "$zshrc" ]] || touch "$zshrc"
    block=$(agent_zsh_block_content "$key_file" "$id")

    if grep -Fxq "$marker" "$zshrc" 2>/dev/null; then
        tmp=$(mktemp)
        awk -v start="$marker" -v end="$end_marker" '
            $0 == start { skip = 1; next }
            skip && $0 == end { skip = 0; next }
            !skip { print }
        ' "$zshrc" > "$tmp"
        { printf '%s\n' "$block"; cat "$tmp"; } > "${zshrc}.git_setup.tmp"
        rm -f "$tmp"
    else
        { printf '%s\n' "$block"; cat "$zshrc"; } > "${zshrc}.git_setup.tmp"
    fi
    mv "${zshrc}.git_setup.tmp" "$zshrc"
}

ensure_ssh_config_block() {
    local ssh_dir="$1"
    local id="$2"
    local privkey_file="$3"
    local config="${ssh_dir}/config"
    local marker="# git_setup.sh: github identity for ${id}"

    touch "$config"
    chmod 600 "$config"
    if grep -Fq "$marker" "$config" 2>/dev/null; then
        return 0
    fi
    cat >> "$config" <<EOF

${marker}
Host github.com
  HostName github.com
  User git
  IdentityFile ${privkey_file}
  IdentitiesOnly yes
EOF
}

op_runner() {
    if [[ -n "${SUDO_USER:-}" ]] && command -v sudo >/dev/null 2>&1; then
        sudo -u "$SUDO_USER" -H "$@"
    else
        "$@"
    fi
}

ensure_op_session() {
    local whoami_out rc=0
    set +e
    whoami_out=$(op_runner op whoami 2>&1)
    rc=$?
    set -e
    if [[ $rc -ne 0 ]] || [[ -z "$whoami_out" ]] || echo "$whoami_out" | grep -qiE 'not currently signed in|no account configured'; then
        log_err "1Password CLI is not signed in."
        if [[ -n "${SUDO_USER:-}" ]]; then
            log_err "Run as ${SUDO_USER}: op signin"
        else
            log_err "Run: op signin"
        fi
        [[ -n "$whoami_out" ]] && log_err "$whoami_out"
        exit 1
    fi
}

run_op_read() {
    local ref="$1"
    local output rc=0
    set +e
    output=$(op_runner op read "$ref" 2>&1)
    rc=$?
    set -e
    if [[ $rc -ne 0 || -z "$output" ]]; then
        log_err "Failed to read from 1Password: $ref"
        [[ -n "$output" ]] && log_err "$output"
        return 1
    fi
    printf '%s' "$output"
}

ensure_ssh_agent_has_key() {
    local key="$1"
    local label="${2:-$key}"

    [[ -f "$key" ]] || return 0
    if ! command -v ssh-add >/dev/null 2>&1; then
        log_warn "ssh-add not found; skipping ssh-agent load for ${label}"
        return 0
    fi

    if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
        eval "$(ssh-agent -s)" >/dev/null
        log "🔐 Started ssh-agent for this session"
    fi

    local fingerprint=""
    fingerprint=$(ssh-keygen -lf "$key" 2>/dev/null | awk '{print $2}') || true
    if [[ -n "$fingerprint" ]] && ssh-add -l 2>/dev/null | grep -qF "$fingerprint"; then
        log "🔐 SSH key already loaded in agent: ${label}"
        return 0
    fi

    log "🔐 Loading SSH key into agent: ${label}"
    if ! ssh-add "$key" </dev/null 2>/dev/null; then
        if ! ssh-add "$key"; then
            log_warn "Could not add ${label} to ssh-agent (passphrase or agent issue)."
            return 1
        fi
    fi
    log_ok "SSH key loaded into agent: ${label}"
}

ensure_local_zshrc_agent_block() {
    local key_file="$1"
    local id="$2"
    install_zshrc_agent_block "$key_file" "$id" "${HOME}/.zshrc"
    log "🔧 Installed ssh-agent auto-load for '${id}' at top of ${HOME}/.zshrc"
}

resolve_user_home() {
    getent passwd "$1" 2>/dev/null | cut -d: -f6 || true
}

expand_path() {
    local path="$1"
    if [[ "$path" == "~/"* ]]; then
        echo "${HOME}/${path:2}"
    elif [[ "$path" == "~" ]]; then
        echo "$HOME"
    else
        echo "$path"
    fi
}

CONNECTION_SSH_KEY_FILE=""
CONNECTION_SSH_KEY_LABEL=""
TEMP_SSH_KEY=false

cleanup_temp_key() {
    if [[ "$TEMP_SSH_KEY" == true && -n "$CONNECTION_SSH_KEY_FILE" ]]; then
        rm -f "$CONNECTION_SSH_KEY_FILE"
    fi
}

cleanup_on_exit() {
    cleanup_temp_key
    cleanup_git_key_temp
}

fetch_op_private_key_to_temp() {
    local ref="$1"
    local label="$2"
    CONNECTION_SSH_KEY_FILE=$(mktemp)
    chmod 600 "$CONNECTION_SSH_KEY_FILE"
    if ! run_op_read "$ref" > "$CONNECTION_SSH_KEY_FILE"; then
        rm -f "$CONNECTION_SSH_KEY_FILE"
        exit 1
    fi
    CONNECTION_SSH_KEY_LABEL="$label"
    TEMP_SSH_KEY=true
    echo "$CONNECTION_SSH_KEY_FILE"
}

# Resolve --ssh-key: local file path or 1Password ID / op:// reference.
resolve_connection_ssh_key() {
    local spec="${1:-}"
    local git_id="${2:-}"
    local candidate expanded

    if [[ -z "$spec" ]]; then
        local defaults=()
        if [[ -n "${SUDO_USER:-}" ]]; then
            local sudo_home
            sudo_home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
            [[ -n "$sudo_home" ]] && defaults+=("${sudo_home}/.ssh/sshkey")
        fi
        defaults+=("${HOME}/.ssh/sshkey")
        [[ -n "$git_id" ]] && defaults+=("${HOME}/.ssh/${git_id}")
        for candidate in "${defaults[@]}"; do
            if [[ -f "$candidate" ]]; then
                CONNECTION_SSH_KEY_LABEL="$candidate"
                TEMP_SSH_KEY=false
                echo "$candidate"
                return
            fi
        done
        if [[ -n "$git_id" ]]; then
            fetch_op_private_key_to_temp "op://dev/sshkey_${git_id}/private key" "1Password:sshkey_${git_id}"
            echo "$CONNECTION_SSH_KEY_FILE"
            return
        fi
        log_err "No SSH key found. Pass --ssh-key <path|id> or place a key at ~/.ssh/sshkey"
        exit 1
    fi

    if [[ "$spec" == op://* ]]; then
        fetch_op_private_key_to_temp "$spec" "$spec"
        echo "$CONNECTION_SSH_KEY_FILE"
        return
    fi

    expanded=$(expand_path "$spec")
    if [[ -f "$expanded" ]]; then
        CONNECTION_SSH_KEY_LABEL="$expanded"
        TEMP_SSH_KEY=false
        echo "$expanded"
        return
    fi

    if [[ -f "${HOME}/.ssh/${spec}" ]]; then
        CONNECTION_SSH_KEY_LABEL="${HOME}/.ssh/${spec}"
        TEMP_SSH_KEY=false
        echo "${HOME}/.ssh/${spec}"
        return
    fi

    fetch_op_private_key_to_temp "op://dev/sshkey_${spec}/private key" "1Password:sshkey_${spec}"
    echo "$CONNECTION_SSH_KEY_FILE"
}

fetch_secrets() {
    local id="$1"
    local name_ref="op://dev/github_${id}/display_name"
    local email_ref="op://dev/github_${id}/email"

    if ! command -v op >/dev/null 2>&1; then
        log_err "1Password CLI (op) is not installed."
        exit 1
    fi

    ensure_op_session
    log "🔑 Fetching credentials from 1Password for ID '$id'..."

    load_git_key_material "$id" || exit 1
    GIT_USER_NAME=$(run_op_read "$name_ref") || true
    GIT_USER_EMAIL=$(run_op_read "$email_ref") || true

    if [[ -z "$GIT_USER_NAME" || -z "$GIT_USER_EMAIL" ]]; then
        log_err "Failed to read Git user.name or user.email from 1Password."
        log_err "Expected: $name_ref and $email_ref"
        exit 1
    fi

    GIT_NAME_B64=$(b64_encode "$GIT_USER_NAME")
    GIT_EMAIL_B64=$(b64_encode "$GIT_USER_EMAIL")
}

write_ssh_key_files() {
    local ssh_dir="$1"
    local id="$2"

    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    cp "$GIT_KEY_PRIV_FILE" "${ssh_dir}/${id}"
    cp "$GIT_KEY_PUB_FILE" "${ssh_dir}/${id}.pub"
    chmod 600 "${ssh_dir}/${id}"
    chmod 644 "${ssh_dir}/${id}.pub"
    validate_ssh_key_file "${ssh_dir}/${id}"
}

deploy_ssh_keys_via_scp() {
    local host="$1"
    local login_user="$2"
    local ssh_key="$3"
    local id="$4"

    ssh -i "$ssh_key" \
        -o BatchMode=yes \
        -o ConnectTimeout=15 \
        -o StrictHostKeyChecking=accept-new \
        -o IdentitiesOnly=yes \
        "${login_user}@${host}" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh"

    scp -i "$ssh_key" \
        -o BatchMode=yes \
        -o ConnectTimeout=15 \
        -o StrictHostKeyChecking=accept-new \
        -o IdentitiesOnly=yes \
        "$GIT_KEY_PRIV_FILE" "$GIT_KEY_PUB_FILE" "${login_user}@${host}:.ssh/"

    ssh -i "$ssh_key" \
        -o BatchMode=yes \
        -o ConnectTimeout=15 \
        -o StrictHostKeyChecking=accept-new \
        -o IdentitiesOnly=yes \
        "${login_user}@${host}" \
        "chmod 600 ~/.ssh/${id} && chmod 644 ~/.ssh/${id}.pub && ssh-keygen -y -f ~/.ssh/${id} >/dev/null"

    log_ok "Deployed SSH keys to ${login_user}@${host}:~/.ssh/${id}"
}

read -r -d '' TARGET_SETUP_SCRIPT <<'TARGET_SCRIPT' || true
set -euo pipefail

ID="$1"
GIT_USER="$2"
LOGIN_USER="$3"
GIT_DEFAULT_BRANCH="${4:-main}"

: "${GIT_NAME_B64:?missing GIT_NAME_B64}"
: "${GIT_EMAIL_B64:?missing GIT_EMAIL_B64}"

echo "[INFO] Remote setup starting for ID=${ID}, git_user=${GIT_USER}, login_user=${LOGIN_USER}" >&2

resolve_user_home() {
    getent passwd "$1" 2>/dev/null | cut -d: -f6 || true
}

target_home=$(resolve_user_home "$GIT_USER")
if [[ -z "$target_home" && "$GIT_USER" != "$LOGIN_USER" ]]; then
    fallback_home=$(resolve_user_home "$LOGIN_USER")
    if [[ -n "$fallback_home" ]]; then
        echo "WARN: OS user '$GIT_USER' not found; configuring login user '$LOGIN_USER' with '${ID}' keys." >&2
        GIT_USER="$LOGIN_USER"
        target_home="$fallback_home"
    fi
fi
if [[ -z "$target_home" ]]; then
    echo "ERROR: User '$GIT_USER' does not exist on this host." >&2
    echo "ERROR: Create the user first or pass --user matching an existing account." >&2
    exit 1
fi

run_as_git_user() {
    if [[ "$(id -un)" == "$GIT_USER" ]]; then
        "$@"
    elif [[ "$(id -un)" == "$LOGIN_USER" ]]; then
        sudo -u "$GIT_USER" -H "$@"
    else
        echo "ERROR: Running as '$(id -un)', expected '$LOGIN_USER' or '$GIT_USER'." >&2
        exit 1
    fi
}

run_as_git_user env \
    ID="$ID" \
    TARGET_HOME="$target_home" \
    GIT_NAME_B64="$GIT_NAME_B64" \
    GIT_EMAIL_B64="$GIT_EMAIL_B64" \
    GIT_DEFAULT_BRANCH="$GIT_DEFAULT_BRANCH" \
    bash -s <<'INNER'
set -euo pipefail

GIT_USER_NAME=$(printf '%s' "$GIT_NAME_B64" | base64 -d)
GIT_USER_EMAIL=$(printf '%s' "$GIT_EMAIL_B64" | base64 -d)

export HOME="$TARGET_HOME"
SSH_DIR="$HOME/.ssh"
PUBKEY_FILE="$SSH_DIR/${ID}.pub"
PRIVKEY_FILE="$SSH_DIR/${ID}"
ZSHRC_FILE="$HOME/.zshrc"

if [[ ! -f "$PRIVKEY_FILE" ]]; then
    echo "ERROR: Missing private key: ${PRIVKEY_FILE}" >&2
    exit 1
fi
if ! ssh-keygen -y -f "$PRIVKEY_FILE" >/dev/null 2>&1; then
    echo "ERROR: Private key is invalid: ${PRIVKEY_FILE}" >&2
    exit 1
fi

install_zshrc_agent_block() {
    local key_file="$1"
    local id="$2"
    local zshrc="$3"
    local marker="# Configure ssh-agent for ${id} (added by git_setup.sh)"
    local end_marker="# --- End ssh-agent config for ${id} ---"
    local block tmp

    [[ -f "$zshrc" ]] || touch "$zshrc"
    block=$(cat <<EOF
# Configure ssh-agent for ${id} (added by git_setup.sh)
if [ -z "\${SSH_AUTH_SOCK:-}" ]; then
  eval "\$(ssh-agent -s)" >/dev/null
fi
_git_setup_key="${key_file}"
if [ -f "\$_git_setup_key" ]; then
  _git_setup_fp=\$(ssh-keygen -lf "\$_git_setup_key" 2>/dev/null | awk '{print \$2}')
  if [ -z "\$_git_setup_fp" ] || ! ssh-add -l 2>/dev/null | grep -qF "\$_git_setup_fp"; then
    ssh-add "\$_git_setup_key" >/dev/null 2>&1 || true
  fi
fi
unset _git_setup_key _git_setup_fp
# --- End ssh-agent config for ${id} ---
EOF
)

    if grep -Fxq "$marker" "$zshrc" 2>/dev/null; then
        tmp=$(mktemp)
        awk -v start="$marker" -v end="$end_marker" '
            $0 == start { skip = 1; next }
            skip && $0 == end { skip = 0; next }
            !skip { print }
        ' "$zshrc" > "$tmp"
        { printf '%s\n' "$block"; cat "$tmp"; } > "${zshrc}.git_setup.tmp"
        rm -f "$tmp"
    else
        { printf '%s\n' "$block"; cat "$zshrc"; } > "${zshrc}.git_setup.tmp"
    fi
    mv "${zshrc}.git_setup.tmp" "$zshrc"
}

ensure_ssh_config_block() {
    local ssh_dir="$1"
    local id="$2"
    local privkey_file="$3"
    local config="${ssh_dir}/config"
    local marker="# git_setup.sh: github identity for ${id}"

    touch "$config"
    chmod 600 "$config"
    if grep -Fq "$marker" "$config" 2>/dev/null; then
        return 0
    fi
    cat >> "$config" <<EOF

${marker}
Host github.com
  HostName github.com
  User git
  IdentityFile ${privkey_file}
  IdentitiesOnly yes
EOF
}

install_zshrc_agent_block "$PRIVKEY_FILE" "$ID" "$ZSHRC_FILE"
ensure_ssh_config_block "$SSH_DIR" "$ID" "$PRIVKEY_FILE"
echo "ssh-agent and SSH config for '${ID}' installed under ${HOME}"

git config --global user.name "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"
git config --global init.defaultBranch "$GIT_DEFAULT_BRANCH"

if command -v ssh-add >/dev/null 2>&1; then
    if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
        eval "$(ssh-agent -s)" >/dev/null
    fi
    key_fp=$(ssh-keygen -lf "$PRIVKEY_FILE" 2>/dev/null | awk '{print $2}') || true
    if [[ -z "$key_fp" ]] || ! ssh-add -l 2>/dev/null | grep -qF "$key_fp"; then
        ssh-add "$PRIVKEY_FILE" >/dev/null 2>&1 || ssh-add "$PRIVKEY_FILE" || true
    fi
fi

echo "SETUP_OK|${PRIVKEY_FILE}|${PUBKEY_FILE}|${GIT_NAME_B64}|${GIT_EMAIL_B64}|$(id -un)"
INNER
TARGET_SCRIPT

write_setup_payload() {
    if [[ -z "${GIT_NAME_B64:-}" || -z "${GIT_EMAIL_B64:-}" ]]; then
        log_err "Setup payload is missing git identity material."
        exit 1
    fi
    printf "export GIT_NAME_B64='%s'\n" "$GIT_NAME_B64"
    printf "export GIT_EMAIL_B64='%s'\n" "$GIT_EMAIL_B64"
    printf '%s' "$TARGET_SETUP_SCRIPT"
}

run_setup() {
    local id="$1" git_user="$2" login_user="$3" host="${4:-}" ssh_key="${5:-}"

    local runner=(bash -s -- "$id" "$git_user" "$login_user" "$GIT_DEFAULT_BRANCH")
    local output rc=0

    if [[ -n "$host" ]]; then
        if [[ ! -f "$ssh_key" ]]; then
            log_err "SSH connection key not available: ${CONNECTION_SSH_KEY_LABEL:-$ssh_key}"
            exit 1
        fi
        set +e
        output=$({ write_setup_payload; } | ssh -i "$ssh_key" \
            -o BatchMode=yes \
            -o ConnectTimeout=15 \
            -o StrictHostKeyChecking=accept-new \
            -o IdentitiesOnly=yes \
            "${login_user}@${host}" \
            "${runner[@]}" 2>&1)
        rc=$?
        set -e
        if [[ $rc -ne 0 ]]; then
            log_err "Remote setup failed on ${login_user}@${host} (exit ${rc})."
            [[ -n "$output" ]] && echo "$output" >&2
            exit 1
        fi
    else
        output=$({ write_setup_payload; } | "${runner[@]}" 2>&1) || {
            log_err "Local setup failed."
            echo "$output" >&2
            exit 1
        }
    fi
    echo "$output"
}

print_summary() {
    local target_label="$1"
    local git_identity="$2"
    local configured_user="$3"
    local privkey_file="$4"
    local pubkey_file="$5"
    local git_name="$6"
    local git_email="$7"
    local host="${8:-}"
    local ssh_user="${9:-}"
    local ssh_key_label="${10:-}"

    echo ""
    log_ok "Setup complete on ${target_label} for git identity '${git_identity}' (OS user: ${configured_user})"
    echo ""
    echo "   Private key : $privkey_file"
    echo "   Public key  : $pubkey_file"
    echo "   Git name    : $git_name"
    echo "   Git email   : $git_email"
    echo ""
    echo "📝 Next steps:"
    echo "   1. Add the public key to GitHub/GitLab if not already done."
    if [[ -n "$host" ]]; then
        echo "   2. When '${ssh_user}' logs into '${host}', '${configured_user}' auto-loads the GitHub key via ~/.zshrc and ~/.ssh/config."
        echo "      ssh -i ${ssh_key_label} ${ssh_user}@${host}"
        if [[ "$configured_user" != "$ssh_user" ]]; then
            echo "      sudo -u ${configured_user} -i   # open a shell as ${configured_user}"
        fi
    else
        echo "   2. Start a new shell (or: source ~/.zshrc) to activate ssh-agent auto-load."
    fi
    echo ""
}

# === ARGUMENT PARSING ===

GIT_USER=""
ID=""  # deprecated alias for --git-user
HOST=""
SSH_USER=""
SSH_KEY_ARG=""
GIT_DEFAULT_BRANCH="main"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --git-user)
            GIT_USER="${2:-}"
            shift 2
            ;;
        --id)
            ID="${2:-}"
            shift 2
            ;;
        --host)
            HOST="${2:-}"
            shift 2
            ;;
        --user)
            SSH_USER="${2:-}"
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
            log_err "Unknown argument: $1"
            usage
            ;;
    esac
done

# --git-user and --id are the same; --git-user takes precedence
if [[ -n "$ID" && -n "$GIT_USER" && "$ID" != "$GIT_USER" ]]; then
    log_err "--id and --git-user must match (got --id '$ID' and --git-user '$GIT_USER')."
    exit 1
fi
GIT_USER="${GIT_USER:-$ID}"

if [[ -z "$GIT_USER" ]]; then
    log_err "--git-user is required (--id is an alias)."
    usage
fi

trap cleanup_on_exit EXIT

SSH_USER="${SSH_USER:-${USER:-$(id -un)}}"
SSH_KEY="$(resolve_connection_ssh_key "$SSH_KEY_ARG" "$GIT_USER")"
[[ -z "$CONNECTION_SSH_KEY_LABEL" ]] && CONNECTION_SSH_KEY_LABEL="$SSH_KEY"

if [[ -n "$HOST" ]]; then
    TARGET_LABEL="${HOST} (login: ${SSH_USER}, git-user: ${GIT_USER})"
else
    TARGET_LABEL="localhost (git-user: ${GIT_USER})"
    if [[ -z "$(resolve_user_home "$GIT_USER")" ]]; then
        log_err "User '$GIT_USER' does not exist locally."
        exit 1
    fi
fi

log "📋 Starting Git and SSH setup for '${GIT_USER}' → ${TARGET_LABEL}"
if [[ -n "$HOST" ]]; then
    log "   SSH key for connection: ${CONNECTION_SSH_KEY_LABEL}"
fi

ensure_ssh_agent_has_key "$SSH_KEY" "${CONNECTION_SSH_KEY_LABEL}"
if [[ "$TEMP_SSH_KEY" == false && -f "$SSH_KEY" ]]; then
    ensure_local_zshrc_agent_block "$SSH_KEY" "$(basename "$SSH_KEY")"
fi

fetch_secrets "$GIT_USER"

if [[ -n "$HOST" ]]; then
    deploy_ssh_keys_via_scp "$HOST" "$SSH_USER" "$SSH_KEY" "$GIT_USER"
else
    git_home=$(resolve_user_home "$GIT_USER")
    write_ssh_key_files "${git_home}/.ssh" "$GIT_USER"
    ensure_ssh_agent_has_key "${git_home}/.ssh/${GIT_USER}" "git identity ${GIT_USER}"
    ensure_local_zshrc_agent_block "${git_home}/.ssh/${GIT_USER}" "$GIT_USER"
    ensure_ssh_config_block "${git_home}/.ssh" "$GIT_USER" "${git_home}/.ssh/${GIT_USER}"
fi

setup_output=$(run_setup "$GIT_USER" "$GIT_USER" "$SSH_USER" "$HOST" "$SSH_KEY")
setup_result=$(echo "$setup_output" | grep '^SETUP_OK|' | tail -n1)

if [[ -z "$setup_result" ]]; then
    log_err "Setup did not complete successfully."
    echo "$setup_output" >&2
    exit 1
fi

IFS='|' read -r _ privkey_file pubkey_file summary_name_b64 summary_email_b64 configured_user <<< "$setup_result"
summary_name=$(printf '%s' "$summary_name_b64" | base64 -d)
summary_email=$(printf '%s' "$summary_email_b64" | base64 -d)

print_summary "$TARGET_LABEL" "$GIT_USER" "$configured_user" "$privkey_file" "$pubkey_file" \
    "$summary_name" "$summary_email" "$HOST" "$SSH_USER" "$CONNECTION_SSH_KEY_LABEL"

exit 0
