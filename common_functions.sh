#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
# ===============================
# Color & Logging Setup
# ===============================

define_logger() {
    # Check if tput is available and TERM is defined
    if command -v tput >/dev/null 2>&1 && [ -n "$TERM" ]; then
        RED=$(tput setaf 1)
        GREEN=$(tput setaf 2)
        YELLOW=$(tput setaf 3)
        BLUE=$(tput setaf 4)
        MAGENTA=$(tput setaf 5)
        CYAN=$(tput setaf 6)
        RESET=$(tput sgr0)
        BOLD=$(tput bold)
    else
        # ANSI Color Fallback
        RED="\033[1;31m"
        GREEN="\033[1;32m"
        YELLOW="\033[1;33m"
        BLUE="\033[1;34m"
        MAGENTA="\033[1;35m"
        CYAN="\033[1;36m"
        RESET="\033[0m"
        BOLD="\033[1m"
    fi
}

# Initialize local logger colors
define_logger

log_message() {
    local level="${1:-INFO}"
    shift
    local message="$*"
    local color

    case "$level" in
        INFO)        color="$BLUE" ;;
        PROCESSING)  color="$MAGENTA" ;;
        DEBUG)       color="$CYAN" ;;
        SUCCESS)     color="$GREEN" ;;
        WARN)        color="$YELLOW" ;;
        ERROR)       color="$RED" ;;
        *)           color="$RESET" ;;
    esac

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [[ "$level" == "ERROR" ]]; then
        printf "%b%s [%s] %s%b\n" "$color" "$timestamp" "$level" "$message" "$RESET" >&2
    else
        printf "%b%s [%s] %s%b\n" "$color" "$timestamp" "$level" "$message" "$RESET"
    fi
}

# Exit with ERROR log
error_exit() {
    log_message "ERROR" "$1"
    exit 1
}

# ------------------------------------------------------------------------------
# Generate and inject logger functions to remote script (for SSH use)
# ------------------------------------------------------------------------------
generate_remote_logger() {
    echo "# --- Begin Remote Logger ---"
    declare -f define_logger
    echo
    declare -f log_message
    echo
    echo "define_logger"
    echo "# --- End Remote Logger ---"
}

# Example: Usage for remote logging (if needed)
log_remote() {
    local level="${1:-INFO}"
    shift
    local msg="$*"
    ssh user@remote_host "$(generate_remote_logger); log_message \"$level\" \"$msg\""
}

log_info()        { echo -e "${BLUE}[INFO]${RESET} $1"; }
log_processing()  { echo -e "${MAGENTA}[PROCESSING]${RESET} $1"; }
log_debug()       { echo -e "${CYAN}[DEBUG]${RESET} $1"; }
log_success()     { echo -e "${GREEN}[SUCCESS]${RESET} $1"; }
log_warn()        { echo -e "${YELLOW}[WARN]${RESET} $1"; }
log_error()       { echo -e "${RED}[ERROR]${RESET} $1" >&2; }  # Redirect to stderr
log_bold()        { echo -e "${BOLD}$1${RESET}"; }

# Check SSH connectivity
check_ssh_connection() {
    local NODE_IP="$1"
    local USER="$2"
    local retries=3
    local timeout=5

    for attempt in $(seq 1 $retries); do
        log_message "INFO" "Attempting SSH connection to $NODE_IP (Attempt $attempt)..."
        if ssh -q -o BatchMode=yes -o ConnectTimeout=$timeout "$USER@$NODE_IP" true; then
            log_message "SUCCESS" "SSH connection successful!"
            return 0
        fi
        log_message "WARN" "Retrying SSH connection..."
        sleep 2
    done

    error_exit "Unable to connect to $NODE_IP via SSH after $retries attempts. Check network or credentials."
}

# Execute remote command over SSH
execute_remote_command() {
    local NODE_IP="$1"
    local USER="$2"
    local COMMAND="$3"

    log_message "PROCESSING" "Executing command on $NODE_IP: $COMMAND"
    ssh -o StrictHostKeyChecking=no "$USER@$NODE_IP" "COMMAND=$COMMAND bash -s" <<EOF
    set -euo pipefail
    $COMMAND
EOF
    if [[ $? -eq 0 ]]; then
        log_message "SUCCESS" "Command executed successfully on $NODE_IP."
    else
        error_exit "Failed to execute command on $NODE_IP."
    fi
}
