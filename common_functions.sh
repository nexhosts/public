#!/bin/bash
set -euo pipefail

# ANSI Color Codes
RESET="\033[0m"
RED="\033[1;31m"       # ERROR → Critical errors, exit points
GREEN="\033[1;32m"     # SUCCESS → Successfully completed tasks
YELLOW="\033[1;33m"    # WARN → Warnings, non-critical issues
BLUE="\033[1;34m"      # INFO → General information
CYAN="\033[1;36m"      # DEBUG → Debugging messages
MAGENTA="\033[1;35m"   # PROCESSING → Tasks in progress

# Logging function
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

    if [ "$level" = "ERROR" ]; then
        printf "%b%s [%s] %s%b\n" "$color" "$timestamp" "$level" "$message" "$RESET" >&2
    else
        printf "%b%s [%s] %s%b\n" "$color" "$timestamp" "$level" "$message" "$RESET"
    fi
}

# Exit script on error
error_exit() {
    log_message "ERROR" "$1"
    exit 1
}

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
