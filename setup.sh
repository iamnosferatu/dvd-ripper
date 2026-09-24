#!/usr/bin/env bash
#
# setup.sh — Prepare an Ubuntu machine to run rip-disc.sh.
#
# Installs all required packages via apt, optionally adds the community
# MakeMKV PPA, adds the current user to the 'cdrom' group for raw optical
# drive access, and creates the default Jellyfin library directories.
#
# Usage:
#   ./setup.sh [-y]
#
#   -y   Assume "yes" to all prompts (still requires sudo for package installs)
#
set -euo pipefail

ASSUME_YES=0
while getopts "yh" opt; do
    case "$opt" in
        y) ASSUME_YES=1 ;;
        h) grep '^#' "$0" | sed -e 's/^#//' -e '1,2d'; exit 0 ;;
        *) exit 1 ;;
    esac
done

log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {
    [[ "$ASSUME_YES" -eq 1 ]] && return 0
    local prompt="$1" reply
    read -r -p "$prompt [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

command -v apt-get >/dev/null 2>&1 || die "This script is for Ubuntu/Debian systems (apt-get not found)."

if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *debian* ]]; then
        warn "This doesn't look like Ubuntu (detected: ${PRETTY_NAME:-unknown}). Continuing anyway."
    fi
fi

log "Updating package lists..."
sudo apt-get update

log "Installing core dependencies..."
sudo apt-get install -y \
    handbrake-cli \
    abcde \
    cdparanoia \
    flac \
    cd-discid \
    genisoimage \
    udisks2 \
    util-linux \
    curl \
    software-properties-common

if command -v makemkvcon >/dev/null 2>&1; then
    log "makemkvcon already installed, skipping."
else
    warn "MakeMKV is not packaged in Ubuntu's official repos."
    if confirm "Add the community MakeMKV PPA (ppa:heyarje/makemkv-beta) and install it?"; then
        sudo add-apt-repository -y ppa:heyarje/makemkv-beta
        sudo apt-get update
        sudo apt-get install -y makemkv-bin makemkv-oss
    else
        warn "Skipping MakeMKV. Install it manually from https://www.makemkv.com/download/ before running rip-disc.sh."
    fi
fi

if id -nG "$USER" | grep -qw cdrom; then
    log "User '$USER' is already in the 'cdrom' group."
else
    if confirm "Add user '$USER' to the 'cdrom' group (required for raw optical-drive access)?"; then
        sudo usermod -aG cdrom "$USER"
        warn "Group membership added. Log out and back in (or reboot) for it to take effect."
    fi
fi

log "Creating Jellyfin library directories..."
mkdir -p "$HOME/Videos/Jellyfin/Movies"
mkdir -p "$HOME/Videos/Jellyfin/TV Shows"
mkdir -p "$HOME/Music/Jellyfin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/rip-disc.sh" ]]; then
    chmod +x "${SCRIPT_DIR}/rip-disc.sh"
fi

log "Setup complete."
echo "  Movies    -> $HOME/Videos/Jellyfin/Movies"
echo "  TV Shows  -> $HOME/Videos/Jellyfin/TV Shows"
echo "  Music     -> $HOME/Music/Jellyfin"
echo
echo "Run './rip-disc.sh' with a disc in the drive to get started."
