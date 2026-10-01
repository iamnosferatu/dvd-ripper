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
    jq \
    eject \
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

if [[ -z "${TMDB_API_KEY:-}" ]]; then
    warn "No TMDB_API_KEY found in your environment."
    echo "rip-disc.sh uses a free TMDb API key to look up movie/TV titles and years"
    echo "for naming, instead of relying on the disc's raw volume label."
    echo "Get one at: https://www.themoviedb.org/settings/api"
    if confirm "Enter a TMDb API key now to save it in ~/.bashrc?"; then
        read -r -p "TMDb API key: " api_key
        if [[ -n "$api_key" ]]; then
            printf '\nexport TMDB_API_KEY=%q\n' "$api_key" >> "$HOME/.bashrc"
            log "Saved to ~/.bashrc. Run 'source ~/.bashrc' or open a new terminal for it to take effect."
            SETUP_TMDB_API_KEY="$api_key"
        fi
    else
        warn "Skipping. rip-disc.sh will fall back to manual naming without a key (pass -K or export TMDB_API_KEY later)."
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
if [[ -f "${SCRIPT_DIR}/sr0-console.sh" ]]; then
    chmod +x "${SCRIPT_DIR}/sr0-console.sh"
fi

# ---------------------------------------------------------------------------
# Optional: fully automatic ripping (udev + systemd), e.g. for a multi-drive
# unattended ripping machine. Each optical drive gets its own service
# instance (rip-disc@sr0.service, rip-disc@sr1.service, ...) started by udev
# the moment media is detected in that drive, running rip-disc.sh -y so it
# never blocks on a prompt. The script's own -E-less default (auto-eject on
# completion) then opens the tray to signal the slot is free again.
# ---------------------------------------------------------------------------
AUTOMATION_NOTE=""
CONSOLE_NOTE=""
RESERVE_DEVICE=""
if [[ ! -f "${SCRIPT_DIR}/rip-disc.sh" ]]; then
    warn "rip-disc.sh not found next to setup.sh — skipping the automation offer."
elif confirm "Set up fully automatic ripping (auto-start on disc insert, auto-eject on completion)?"; then
    log "Installing udev rule and systemd service..."

    MAX_ENCODES=2
    if ! [[ "$ASSUME_YES" -eq 1 ]]; then
        read -r -p "Max simultaneous HandBrake encodes across all drives [2]: " reply
        [[ -n "$reply" ]] && MAX_ENCODES="$reply"
    fi
    [[ "$MAX_ENCODES" =~ ^[0-9]+$ ]] || { warn "Not a number, defaulting to 2."; MAX_ENCODES=2; }

    if confirm "Reserve one drive for always-interactive ripping instead (e.g. sr0, for TV shows/Blu-ray/other edge cases)?"; then
        read -r -p "Which device? [/dev/sr0]: " reserve_reply
        RESERVE_DEVICE="${reserve_reply:-/dev/sr0}"
    fi

    sudo tee /etc/rip-disc.env >/dev/null <<EOF
# Environment for rip-disc@*.service (systemd EnvironmentFile format: KEY=VALUE, no 'export').
TMDB_API_KEY=${SETUP_TMDB_API_KEY:-}
EOF
    sudo chmod 600 /etc/rip-disc.env

    sudo tee /etc/systemd/system/rip-disc@.service >/dev/null <<EOF
[Unit]
Description=Auto-rip disc in /dev/%i
After=udisks2.service local-fs.target
Wants=udisks2.service

[Service]
Type=oneshot
User=${USER}
EnvironmentFile=-/etc/rip-disc.env
ExecStart=${SCRIPT_DIR}/rip-disc.sh -d /dev/%i -y -j ${MAX_ENCODES}
StandardOutput=journal
StandardError=journal
TimeoutStartSec=0
EOF

    EXCLUDE_CLAUSE=""
    if [[ -n "$RESERVE_DEVICE" ]]; then
        EXCLUDE_CLAUSE=", KERNEL!=\"$(basename "$RESERVE_DEVICE")\""
    fi

    sudo tee /etc/udev/rules.d/99-rip-disc.rules >/dev/null <<EOF
# Auto-start rip-disc@<device>.service whenever media is inserted into an
# optical drive. ID_CDROM_MEDIA=="1" only matches insertion, not ejection,
# so this doesn't re-trigger when rip-disc.sh itself ejects on completion.
ACTION=="change", SUBSYSTEM=="block", KERNEL=="sr[0-9]*"${EXCLUDE_CLAUSE}, ENV{ID_CDROM_MEDIA}=="1", TAG+="systemd", ENV{SYSTEMD_WANTS}="rip-disc@%k.service"
EOF

    sudo udevadm control --reload-rules
    sudo systemctl daemon-reload

    log "Automation installed."
    AUTOMATION_NOTE="Automatic ripping is ON (max ${MAX_ENCODES} simultaneous encode(s)): insert a disc in any drive and it'll start ripping on its own."
    [[ -n "$RESERVE_DEVICE" ]] && AUTOMATION_NOTE="${AUTOMATION_NOTE} ${RESERVE_DEVICE} is excluded from this — see below."
    echo "  - Check progress: journalctl -u rip-disc@sr1 -f   (replace sr1 with the drive)"
    echo "  - Change TMDb key later: sudo nano /etc/rip-disc.env"
    echo "  - Change the encode concurrency limit: edit the -j value in /etc/systemd/system/rip-disc@.service, then run 'sudo systemctl daemon-reload'"
    echo "  - Uninstall: sudo rm /etc/udev/rules.d/99-rip-disc.rules /etc/systemd/system/rip-disc@.service /etc/rip-disc.env && sudo udevadm control --reload-rules && sudo systemctl daemon-reload"

    if [[ -n "$RESERVE_DEVICE" ]]; then
        if [[ ! -f "${SCRIPT_DIR}/sr0-console.sh" ]]; then
            warn "sr0-console.sh not found next to setup.sh — skipping the interactive-console offer. ${RESERVE_DEVICE} will just sit unautomated; run './rip-disc.sh -d ${RESERVE_DEVICE}' manually."
        elif confirm "Install an always-on interactive console for ${RESERVE_DEVICE} (prompts on a virtual terminal whenever a disc is inserted)?"; then
            CONSOLE_TTY="/dev/tty9"
            if ! [[ "$ASSUME_YES" -eq 1 ]]; then
                read -r -p "Which virtual terminal should it use? [/dev/tty9]: " tty_reply
                [[ -n "$tty_reply" ]] && CONSOLE_TTY="$tty_reply"
            fi
            CONSOLE_TTY_NAME="$(basename "$CONSOLE_TTY")"

            sudo tee /etc/systemd/system/rip-disc-console.service >/dev/null <<EOF
[Unit]
Description=Interactive rip-disc.sh console for ${RESERVE_DEVICE}
After=udisks2.service local-fs.target getty@${CONSOLE_TTY_NAME}.service
Wants=udisks2.service
Conflicts=getty@${CONSOLE_TTY_NAME}.service

[Service]
Type=simple
User=${USER}
EnvironmentFile=-/etc/rip-disc.env
ExecStart=${SCRIPT_DIR}/sr0-console.sh ${RESERVE_DEVICE} -j ${MAX_ENCODES}
StandardInput=tty-force
StandardOutput=tty
TTYPath=${CONSOLE_TTY}
TTYReset=yes
TTYVHangup=yes
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

            sudo systemctl daemon-reload
            sudo systemctl enable --now rip-disc-console.service

            log "Interactive console installed for ${RESERVE_DEVICE}."
            CONSOLE_NOTE="Interactive console is ON for ${RESERVE_DEVICE}: switch to ${CONSOLE_TTY} (commonly Ctrl+Alt+F9, but check your system) to see and answer its prompts whenever a disc is inserted."
            echo "  - Watch it remotely: sudo systemctl status rip-disc-console.service"
            echo "  - Uninstall it: sudo systemctl disable --now rip-disc-console.service && sudo rm /etc/systemd/system/rip-disc-console.service && sudo systemctl daemon-reload"
        else
            CONSOLE_NOTE="${RESERVE_DEVICE} is excluded from automation but no console was installed — run './rip-disc.sh -d ${RESERVE_DEVICE}' manually when needed."
        fi
    fi
else
    AUTOMATION_NOTE="Automatic ripping is OFF: run './rip-disc.sh' manually per disc (rerun setup.sh to enable it later)."
fi

log "Setup complete."
echo "  Movies    -> $HOME/Videos/Jellyfin/Movies"
echo "  TV Shows  -> $HOME/Videos/Jellyfin/TV Shows"
echo "  Music     -> $HOME/Music/Jellyfin"
echo
echo "$AUTOMATION_NOTE"
[[ -n "$CONSOLE_NOTE" ]] && echo "$CONSOLE_NOTE"
echo
echo "Run './rip-disc.sh' with a disc in the drive to get started."
