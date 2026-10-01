#!/usr/bin/env bash
#
# sr0-console.sh — Persistent interactive console for one reserved optical
# drive (e.g. sr0), for discs that need a human to pick the mode: TV shows,
# Blu-ray box sets, or anything else auto-detection/full automation can't
# safely decide on its own.
#
# Intended to run attached to a dedicated virtual terminal as a long-running
# systemd service (see setup.sh, which offers to install it). Loops forever:
#
#   wait for a disc to appear in DEVICE
#     -> run rip-disc.sh on it with NO -y (so it prompts: Movie or TV show?,
#        season number, TMDb match, etc. — same prompts as running it by
#        hand)
#     -> wait for the drive to be empty again (the disc is auto-ejected on
#        success, same as any other drive; a failed rip just leaves the
#        disc in place for you to deal with)
#     -> repeat
#
# This script never calls `set -e`, deliberately — if one disc's rip fails
# or is aborted, the console keeps running and waits for the next disc
# instead of exiting (which would otherwise flap the systemd service).
#
# Usage:
#   ./sr0-console.sh [DEVICE] [-- extra rip-disc.sh flags]
#
#   DEVICE   Optical drive device to watch (default: /dev/sr0)
#
# Any arguments after DEVICE (or all arguments, if DEVICE is omitted) are
# forwarded to rip-disc.sh on every run — e.g. to set -j, -o, or -K.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEVICE="/dev/sr0"
if [[ $# -gt 0 && "$1" != -* ]]; then
    DEVICE="$1"
    shift
fi

disc_present() {
    blkid -o value -s TYPE "$DEVICE" >/dev/null 2>&1 || cdparanoia -Q -d "$DEVICE" >/dev/null 2>&1
}

echo "=========================================================="
echo " rip-disc.sh interactive console — $DEVICE"
echo " For TV shows, Blu-ray discs, and other edge cases."
echo " Insert a disc here any time — this will prompt you for"
echo " what to do with it."
echo "=========================================================="

while true; do
    echo
    echo "Waiting for a disc in $DEVICE..."
    until disc_present; do
        sleep 3
    done

    echo
    echo "Disc detected in $DEVICE — starting rip-disc.sh."
    "${SCRIPT_DIR}/rip-disc.sh" -d "$DEVICE" "$@"
    status=$?
    if [[ "$status" -ne 0 ]]; then
        echo
        echo "rip-disc.sh exited with status $status — check the disc and try again, or remove it."
    fi

    echo
    echo "Waiting for $DEVICE to be empty before watching for the next disc..."
    while disc_present; do
        sleep 3
    done
done
