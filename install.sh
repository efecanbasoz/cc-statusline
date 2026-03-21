#!/bin/bash
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
TARGET="$CLAUDE_DIR/statusline.sh"
SCRIPT_BACKUP="$CLAUDE_DIR/statusline.sh.cc-backup"
CONFIG_BACKUP="$CLAUDE_DIR/statusline-config.cc-backup.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EDITION=""

STATUSLINE_VALUE='{"type":"command","command":"~/.claude/statusline.sh"}'

# Colors
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
DIM='\033[2m'
RESET='\033[0m'

info()  { printf "${GREEN}[ok]${RESET} %s\n" "$1"; }
warn()  { printf "${YELLOW}[!!]${RESET} %s\n" "$1"; }
error() { printf "${RED}[err]${RESET} %s\n" "$1"; }

usage() {
    echo "Usage: install.sh [--edition slim|full] [--uninstall] [--help]"
    echo ""
    echo "  (no args)         Interactive edition selection"
    echo "  --edition slim    Install slim edition"
    echo "  --edition full    Install full edition"
    echo "  --uninstall       Remove cc-statusline and restore previous config"
    echo "  --help            Show this help message"
}

check_deps() {
    # jq is required by the installer itself — hard fail
    if ! command -v jq &>/dev/null; then
        error "jq is required for installation. Install it first:"
        echo "    apt:    sudo apt install jq"
        echo "    brew:   brew install jq"
        echo "    pacman: sudo pacman -S jq"
        exit 1
    fi

    # python3 and bc are runtime deps for the statusline — warn only
    local missing=()
    for cmd in python3 bc; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        warn "Missing runtime dependencies: ${missing[*]}"
        echo "  The statusline needs these to display cost data."
        echo "  Install with:"
        echo "    apt:    sudo apt install ${missing[*]}"
        echo "    brew:   brew install ${missing[*]}"
        echo "    pacman: sudo pacman -S ${missing[*]}"
        echo ""
    fi

    if [ "$EDITION" = "full" ]; then
        local full_missing=()
        for cmd in curl git; do
            if ! command -v "$cmd" &>/dev/null; then
                full_missing+=("$cmd")
            fi
        done
        if [ ${#full_missing[@]} -gt 0 ]; then
            warn "Missing optional dependencies for full edition: ${full_missing[*]}"
            echo ""
        fi
    fi
}

select_edition() {
    if [ -n "$EDITION" ]; then return; fi
    echo "Select edition:"
    echo "  1) slim  — context, cost, session info (lightweight)"
    echo "  2) full  — everything in slim + git, rate limits, tool tracking (recommended)"
    printf "Choice [2]: "
    read -r choice
    case "${choice:-2}" in
        1) EDITION="slim" ;;
        *) EDITION="full" ;;
    esac
}

do_install() {
    select_edition
    check_deps

    local SOURCE="$SCRIPT_DIR/${EDITION}/statusline.sh"
    mkdir -p "$CLAUDE_DIR"

    if [ ! -f "$SOURCE" ]; then
        error "Source script not found: $SOURCE"
        exit 1
    fi

    # Backup existing statusline script
    if [ -f "$TARGET" ]; then
        cp "$TARGET" "$SCRIPT_BACKUP"
        info "Backed up existing statusline to ${SCRIPT_BACKUP##*/}"
    fi

    # Copy script
    cp "$SOURCE" "$TARGET"
    chmod +x "$TARGET"
    info "Installed statusline.sh to $TARGET"

    # Update settings.json
    if [ ! -f "$SETTINGS_FILE" ]; then
        echo '{}' > "$SETTINGS_FILE"
        info "Created $SETTINGS_FILE"
    fi

    # Backup existing statusLine config if present
    local existing
    existing=$(jq -r '.statusLine // empty' "$SETTINGS_FILE" 2>/dev/null)
    if [ -n "$existing" ]; then
        jq '.statusLine' "$SETTINGS_FILE" > "$CONFIG_BACKUP"
        info "Backed up existing statusLine config"
    fi

    # Set statusLine in settings.json
    local tmp
    tmp=$(mktemp)
    jq --argjson sl "$STATUSLINE_VALUE" '.statusLine = $sl' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
    info "Updated settings.json with statusLine config"

    echo ""
    echo -e "${GREEN}cc-statusline (${EDITION}) installed!${RESET}"
    echo -e "${DIM}Restart Claude Code to see the statusline.${RESET}"
}

do_uninstall() {
    # Restore or remove statusline script
    if [ -f "$SCRIPT_BACKUP" ]; then
        mv "$SCRIPT_BACKUP" "$TARGET"
        info "Restored previous statusline.sh"
    elif [ -f "$TARGET" ]; then
        rm "$TARGET"
        info "Removed statusline.sh"
    else
        warn "No statusline.sh found, nothing to remove"
    fi

    # Restore or remove statusLine config
    if [ -f "$SETTINGS_FILE" ]; then
        if [ -f "$CONFIG_BACKUP" ]; then
            local backup_val
            backup_val=$(cat "$CONFIG_BACKUP")
            local tmp
            tmp=$(mktemp)
            jq --argjson sl "$backup_val" '.statusLine = $sl' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
            rm "$CONFIG_BACKUP"
            info "Restored previous statusLine config"
        elif jq -e --argjson sl "$STATUSLINE_VALUE" '.statusLine == $sl' "$SETTINGS_FILE" >/dev/null 2>&1; then
            local tmp
            tmp=$(mktemp)
            jq 'del(.statusLine)' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
            info "Removed statusLine from settings.json"
        else
            warn "statusLine config does not match cc-statusline, leaving it untouched"
        fi
    fi

    # Explicit cleanup of any remaining backup files
    rm -f "$SCRIPT_BACKUP" "$CONFIG_BACKUP"

    echo ""
    echo -e "${GREEN}cc-statusline uninstalled.${RESET}"
}

case "${1:-}" in
    --help|-h)
        usage
        ;;
    --uninstall)
        do_uninstall
        ;;
    --edition)
        EDITION="${2:-}"
        if [ "$EDITION" != "slim" ] && [ "$EDITION" != "full" ]; then
            error "Invalid edition: $EDITION (use 'slim' or 'full')"
            exit 1
        fi
        do_install
        ;;
    "")
        do_install
        ;;
    *)
        error "Unknown option: $1"
        usage
        exit 1
        ;;
esac
