#!/usr/bin/env bash
# Wrapper script - calls part1.sh and part2.sh
# For details, see:
# - install-xfce-xrdp-part1.sh (system installation)
# - install-xfce-xrdp-part2.sh (GUI configuration)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_URL="https://raw.githubusercontent.com/hexbyte42-bot/cyber-claw/main"

log() { printf "\n\033[1;32m[+] %s\033[0m\n" "$*"; }

if [[ $# -gt 0 && "$1" == "--part2" ]]; then
    log "Running Part 2 (GUI configuration)..."
    if [[ -f "$SCRIPT_DIR/install-xfce-xrdp-part2.sh" ]]; then
        bash "$SCRIPT_DIR/install-xfce-xrdp-part2.sh" "$@"
    else
        curl -fsSL "$SCRIPT_URL/install-xfce-xrdp-part2.sh" | bash -s -- "$@"
    fi
else
    log "Running Part 1 (system installation)..."
    if [[ -f "$SCRIPT_DIR/install-xfce-xrdp-part1.sh" ]]; then
        bash "$SCRIPT_DIR/install-xfce-xrdp-part1.sh" "$@"
    else
        curl -fsSL "$SCRIPT_URL/install-xfce-xrdp-part1.sh" | bash -s -- "$@"
    fi
fi
