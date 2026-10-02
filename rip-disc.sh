#!/usr/bin/env bash
#
# rip-disc.sh — Rip a DVD/Blu-ray (movie or TV) or audio CD into a
# Jellyfin-ready library.
#
# Auto-detects what's in the drive and routes to the right pipeline:
#   Audio CD        -> abcde (cdparanoia + FLAC + MusicBrainz tagging)
#   DVD/Blu-ray, movie -> MakeMKV (main feature) -> [optional] HandBrakeCLI
#   DVD/Blu-ray, TV    -> MakeMKV title scan -> interactive confirmation of
#                         which titles map to which episodes -> [optional]
#                         HandBrakeCLI, named S01E01...
#
# Rip-only by default: video discs are ripped with MakeMKV straight to their
# final Jellyfin name (lossless, no re-encode) and ejected. Each raw rip gets
# a sidecar marker (Name.mkv.raw). Encoding is opt-in: pass -e (or set
# ENCODE_AFTER_RIP=1 in ~/.config/rip-disc/config) to encode right after the
# rip, or run `./rip-disc.sh -m encode` later to pick which raw files to
# encode. An encode replaces the raw file in place, only after the new file
# has been verified; the raw file is never deleted before that.
#
# Config file (~/.config/rip-disc/config, override path with RIP_DISC_CONFIG),
# plain shell assignments read before flags are parsed, e.g.:
#   ENCODE_AFTER_RIP=0   QUALITY=20   HW_ENCODE=0   MIN_FREE_GB=10
#
# For a video disc, auto mode asks "Movie or TV show?" (and, for TV, the
# season number) unless -y or an explicit -m is given — see "Unattended /
# multi-drive operation" below for how to skip this on automated drives.
#
# Requirements (Ubuntu):
#   Run ./setup.sh to install everything automatically, or manually:
#     sudo apt-get install -y handbrake-cli abcde cdparanoia flac cd-discid genisoimage udisks2 jq eject
#   MakeMKV: not in Ubuntu's official repos. setup.sh offers to add the
#   community ppa:heyarje/makemkv-beta PPA, or install manually from
#   https://www.makemkv.com/download/
#
# Metadata lookup (movie/TV naming):
#   When -n isn't given, movie and TV modes search themoviedb.org (TMDb) using
#   the disc label as the query and let you confirm the match interactively,
#   so folders/files are named from real metadata (correct title + year)
#   instead of a raw disc label. Requires a free TMDb API key (from
#   https://www.themoviedb.org/settings/api) exported as TMDB_API_KEY, or
#   passed with -K. Without a key, or with -M, lookup is skipped and it falls
#   back to prompting for a manual name (same as before). Music mode already
#   gets database-driven naming for free via MusicBrainz (through abcde).
#
# Unattended / multi-drive operation:
#   Pass -y to disable every interactive prompt: TMDb matches auto-pick the
#   top result, TV mode auto-accepts all titles above -l in disc order, and
#   manual-name fallbacks just use the (sanitized) disc label. This is
#   required when running from udev/systemd with no attached terminal — a
#   `read` with no input would otherwise abort the script under `set -e`.
#   See setup.sh for a udev+systemd installer that runs this automatically,
#   per drive, whenever a disc is inserted — see the "automatic" section of
#   the README for an 8-drive style batch ripping setup.
#
#   MakeMKV's raw rip is disc I/O, not CPU, so every drive can do that step
#   at once with no contention. The disc is ejected (see -E) as soon as its
#   raw rip is verified — never after encoding — since the drive is not
#   touched again once the rip is on local disk. HandBrake's x265 encode is
#   CPU-heavy, so -j caps how many encodes run at once *across all drives*
#   (a flock-based limit shared by every rip-disc.sh process).
#
#   Free-space guard: before ripping, the script reserves roughly the disc's
#   size (plus a MIN_FREE_GB headroom, -f) against the library filesystem,
#   counting reservations made by other rips in progress, and refuses to
#   start if there isn't room — leaving the disc in the drive. Encodes
#   reserve about half the raw file's size for the new file.
#
#   Integrity check: each rip is verified with ffprobe (has video + audio
#   streams, and is not truncated) before it is moved into the library. A
#   rip that fails is renamed Name.mkv.failed and the disc is NOT ejected.
#
# Usage:
#   ./rip-disc.sh [-d /dev/sr0] [-m auto|movie|tv|music|encode] [-n "Name"]
#                 [-s SEASON] [-o /path/to/library] [-q QUALITY]
#                 [-l MINLENGTH_SECONDS] [-L eng,fre,...] [-K TMDB_API_KEY]
#                 [-M] [-y] [-E] [-j N] [-H] [-e|-r] [-f GB] [FILE...]
#
#   -d DEVICE     Optical drive device (default: /dev/sr0)
#   -m MODE       auto (default) | movie | tv | music | encode
#                 encode: no disc needed — encode raw rips already in the
#                 library (pick interactively, or pass FILE paths; with -y
#                 encode everything pending). Replaces each raw file in place.
#   -n NAME       Movie title "Name (Year)", or TV show name. Skips TMDb lookup
#                 entirely and uses this name as given.
#   -s SEASON     Season number for TV mode (default: 1)
#   -o ROOT       Library root. Subfolders Movies/, TV Shows/, Music/ are created under it.
#                 (default: ~/Videos/Jellyfin for video, ~/Music/Jellyfin for audio)
#   -q QUALITY    x265 CRF for video encodes (default: 20; lower = higher quality/bigger file)
#   -l MINLENGTH  Minimum title length in seconds for MakeMKV to keep (default: 120)
#   -L LANGS      Comma-separated subtitle language codes to include, if present on the
#                 disc (default: eng). Soft subtitles only — never burned in.
#   -K API_KEY    TMDb API key (overrides the TMDB_API_KEY environment variable)
#   -M            Disable TMDb metadata lookup even if an API key is available
#   -y            Non-interactive: auto-pick TMDb's top match / all titles in disc
#                 order instead of prompting (required for udev/systemd triggering)
#   -E            Disable auto-eject on completion (by default the tray opens
#                 when the rip finishes, so you know the drive is free again)
#   -j N          Max concurrent HandBrake encodes system-wide (default: 2; 0 = unlimited)
#   -H            Hardware-encode with Intel Quick Sync (qsv_h265) instead of
#                 software x265. Much faster, but typically less efficient
#                 compression at the same quality (bigger files). Needs
#                 HandBrakeCLI built with QSV/oneVPL support and the Intel
#                 media driver installed (setup.sh offers this) — the script
#                 verifies the encoder is actually available before ripping.
#   -e            Encode right after the rip (default is rip-only, unless
#                 ENCODE_AFTER_RIP=1 is set in the config file)
#   -r            Rip only, no encode (overrides ENCODE_AFTER_RIP=1 in config)
#   -f GB         Free-space headroom to keep beyond the estimated need
#                 (default: 10; 0 disables the free-space guard entirely)
#
# Interactive runs (no -y) with neither -e nor -r ask "Encode after ripping?".
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DEVICE="/dev/sr0"
MODE="auto"
NAME=""
SEASON="1"
VIDEO_OUTPUT_ROOT="${HOME}/Videos/Jellyfin"
MUSIC_OUTPUT_ROOT="${HOME}/Music/Jellyfin"
OUTPUT_ROOT_OVERRIDE=""
QUALITY=20
MINLENGTH=120
SUBTITLE_LANGS="eng"
TMDB_API_KEY="${TMDB_API_KEY:-}"
LOOKUP_DISABLED=0
NONINTERACTIVE=0
AUTO_EJECT=1
MAX_ENCODES=2
HW_ENCODE=0
ENCODE_AFTER_RIP=0
ENCODE_FLAG_SET=0
MIN_FREE_GB=10
RIPPED_FILES=()
ENCODE_PATHS=()
RIP_ROOT=""
RIP_TMP=""
WORKDIR="$(mktemp -d /tmp/discrip.XXXXXX)"

# Optional config file: plain shell assignments overriding the defaults above
# (flags still win). Lets the udev/systemd automation pick up a global setting
# like ENCODE_AFTER_RIP without editing any unit files.
CONFIG_FILE="${RIP_DISC_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/rip-disc/config}"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

MOUNTED_BY_US=0
MOUNT_POINT=""

cleanup() {
    if [[ "$MOUNTED_BY_US" -eq 1 && -n "$MOUNT_POINT" ]]; then
        udisksctl unmount -b "$DEVICE" >/dev/null 2>&1 || true
    fi
    if declare -F release_space >/dev/null; then
        release_space
    fi
    if [[ -n "$RIP_TMP" && -d "$RIP_TMP" ]]; then
        rm -rf "$RIP_TMP"
        rmdir "$(dirname "$RIP_TMP")" 2>/dev/null || true
    fi
    if [[ -d "$WORKDIR" ]]; then
        rm -rf "$WORKDIR"
    fi
}
trap cleanup EXIT

usage() {
    grep '^#' "$0" | sed -e 's/^#//' -e '1,2d'
    exit 0
}

sanitize() {
    echo "$1" | tr -cd '[:alnum:] ._()-' | sed -e 's/  */ /g' -e 's/^ *//' -e 's/ *$//'
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while getopts "d:m:n:s:o:q:l:L:K:MyEj:Herf:h" opt; do
    case "$opt" in
        d) DEVICE="$OPTARG" ;;
        m) MODE="$OPTARG" ;;
        n) NAME="$OPTARG" ;;
        s) SEASON="$OPTARG" ;;
        o) OUTPUT_ROOT_OVERRIDE="$OPTARG" ;;
        q) QUALITY="$OPTARG" ;;
        l) MINLENGTH="$OPTARG" ;;
        L) SUBTITLE_LANGS="$OPTARG" ;;
        K) TMDB_API_KEY="$OPTARG" ;;
        M) LOOKUP_DISABLED=1 ;;
        y) NONINTERACTIVE=1 ;;
        E) AUTO_EJECT=0 ;;
        j) MAX_ENCODES="$OPTARG" ;;
        H) HW_ENCODE=1 ;;
        e) ENCODE_AFTER_RIP=1; ENCODE_FLAG_SET=1 ;;
        r) ENCODE_AFTER_RIP=0; ENCODE_FLAG_SET=1 ;;
        f) MIN_FREE_GB="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
ENCODE_PATHS=("$@")

[[ "$MAX_ENCODES" =~ ^[0-9]+$ ]] || die "Invalid -j value '$MAX_ENCODES': must be a non-negative integer (0 = unlimited)."
[[ "$MIN_FREE_GB" =~ ^[0-9]+$ ]] || die "Invalid -f value '$MIN_FREE_GB': must be a non-negative integer (0 = disable the guard)."
[[ "$ENCODE_AFTER_RIP" =~ ^[01]$ ]] || die "ENCODE_AFTER_RIP must be 0 or 1 (check $CONFIG_FILE)."

case "$MODE" in
    auto|movie|tv|music|encode) ;;
    *) die "Invalid mode '$MODE'. Use auto, movie, tv, music, or encode." ;;
esac

if [[ "$MODE" != "encode" ]]; then
    [[ -b "$DEVICE" ]] || die "Device '$DEVICE' does not look like a block device. Pass the correct drive with -d."
fi

RIP_ROOT="${OUTPUT_ROOT_OVERRIDE:-$VIDEO_OUTPUT_ROOT}"

# ---------------------------------------------------------------------------
# Disc type detection
# ---------------------------------------------------------------------------
detect_disc_type() {
    # Audio CDs have no filesystem — blkid reports no TYPE for them.
    local fs_type
    fs_type="$(blkid -o value -s TYPE "$DEVICE" 2>/dev/null || true)"

    if [[ -z "$fs_type" ]]; then
        if cdparanoia -Q -d "$DEVICE" >/dev/null 2>&1; then
            echo "music"
            return
        fi
        die "Could not identify disc: no filesystem and no audio TOC found. Is a disc inserted?"
    fi

    # Filesystem present (UDF/ISO9660) -> DVD-Video, Blu-ray, or data disc.
    # Mount to check for VIDEO_TS (DVD) or BDMV (Blu-ray).
    local udisk_out
    udisk_out="$(udisksctl mount -b "$DEVICE" 2>&1)" || die "Failed to mount $DEVICE: $udisk_out"
    MOUNT_POINT="$(echo "$udisk_out" | sed -n "s/.*at \(.*\)\.$/\1/p")"
    MOUNTED_BY_US=1

    if [[ -d "${MOUNT_POINT}/VIDEO_TS" || -d "${MOUNT_POINT}/BDMV" ]]; then
        echo "video"
    else
        die "Disc at $DEVICE doesn't look like a DVD-Video/Blu-ray disc or audio CD (no VIDEO_TS or BDMV, no audio TOC). Data discs aren't supported by this script."
    fi
}

resolve_disc_label() {
    lsblk -no LABEL "$DEVICE" 2>/dev/null | head -n1 | tr -s ' _' '  ' | sed -e 's/^ *//' -e 's/ *$//'
}

# ---------------------------------------------------------------------------
# TMDb metadata lookup (movie/TV naming from a real database instead of the
# disc's often-garbled volume label)
# ---------------------------------------------------------------------------
LOOKUP_TITLE=""
LOOKUP_YEAR=""

lookup_available() {
    [[ "$LOOKUP_DISABLED" -eq 0 && -n "$TMDB_API_KEY" ]] || return 1
    command -v curl >/dev/null 2>&1 || { warn "'curl' not found; skipping TMDb lookup."; return 1; }
    command -v jq >/dev/null 2>&1 || { warn "'jq' not found; skipping TMDb lookup. Install with: sudo apt-get install -y jq"; return 1; }
    return 0
}

# Search TMDb for $2 (kind = movie|tv) matching $1 (query text), and let the
# user interactively confirm a result. On success, sets LOOKUP_TITLE (and
# LOOKUP_YEAR, if known) and returns 0. Returns 1 if the user declines, there
# are no matches, or the request fails — callers should fall back gracefully.
lookup_metadata() {
    local kind="$1" query="$2"
    local title_field year_field
    if [[ "$kind" == "movie" ]]; then title_field="title"; year_field="release_date"
    else title_field="name"; year_field="first_air_date"; fi

    local resp
    resp="$(curl -sS --fail --get "https://api.themoviedb.org/3/search/${kind}" \
        --data-urlencode "api_key=${TMDB_API_KEY}" \
        --data-urlencode "query=${query}" \
        --data-urlencode "include_adult=false" 2>/dev/null)" || {
        warn "TMDb lookup failed (network error or invalid API key)."
        return 1
    }

    local count
    count="$(echo "$resp" | jq -r '.results | length' 2>/dev/null || echo 0)"
    if [[ -z "$count" || "$count" -eq 0 ]]; then
        warn "No TMDb matches for '$query'."
        return 1
    fi
    [[ "$count" -gt 8 ]] && count=8

    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
        LOOKUP_TITLE="$(echo "$resp" | jq -r ".results[0].${title_field}")"
        LOOKUP_YEAR="$(echo "$resp" | jq -r ".results[0].${year_field} // \"\"" | cut -c1-4)"
        log "Non-interactive: auto-picked top TMDb match '$LOOKUP_TITLE (${LOOKUP_YEAR:-unknown year})' for '$query'."
        return 0
    fi

    echo
    echo "TMDb matches for '$query':"
    local i t y
    for (( i=0; i<count; i++ )); do
        t="$(echo "$resp" | jq -r ".results[$i].${title_field}")"
        y="$(echo "$resp" | jq -r ".results[$i].${year_field} // \"\"" | cut -c1-4)"
        printf '  %d) %s (%s)\n' "$((i + 1))" "$t" "${y:-unknown year}"
    done
    echo "  0) None of these — enter the name manually"

    local choice
    read -r -p "Pick a match [0-${count}]: " choice
    [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "$count" ]] || return 1

    local idx=$((choice - 1))
    LOOKUP_TITLE="$(echo "$resp" | jq -r ".results[$idx].${title_field}")"
    LOOKUP_YEAR="$(echo "$resp" | jq -r ".results[$idx].${year_field} // \"\"" | cut -c1-4)"
    return 0
}

# ---------------------------------------------------------------------------
# Music mode: audio CD -> FLAC via abcde (cdparanoia + MusicBrainz tagging)
# ---------------------------------------------------------------------------
rip_music() {
    for bin in abcde cdparanoia flac; do
        command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found. Install with: sudo dnf install abcde cdparanoia flac cd-discid"
    done

    local output_root="${OUTPUT_ROOT_OVERRIDE:-$MUSIC_OUTPUT_ROOT}"
    mkdir -p "$output_root"

    local abcde_conf="${WORKDIR}/abcde.conf"
    cat > "$abcde_conf" <<EOF
OUTPUTDIR="${output_root}"
OUTPUTTYPE="flac"
FLACOPTS="--best --verify"
OUTPUTFORMAT='\${ARTISTFILE}/\${ALBUMFILE}/\${TRACKNUM} - \${TRACKFILE}'
VAOUTPUTFORMAT='Various Artists/\${ALBUMFILE}/\${TRACKNUM} - \${ARTISTFILE} - \${TRACKFILE}'
CDDBMETHOD=musicbrainz
ACTIONS=cddb,read,encode,tag,move,clean
EJECT=n
mkdircmd='mkdir -p'
EOF

    log "Ripping audio CD to FLAC (this queries MusicBrainz for album/track metadata)..."
    log "Output library: $output_root"

    abcde -N -d "$DEVICE" -c "$abcde_conf"

    log "Music rip complete. Point a Jellyfin Music library at: $output_root"
    eject_disc
}

# ---------------------------------------------------------------------------
# Shared: MakeMKV raw extraction
# ---------------------------------------------------------------------------
check_video_deps() {
    local bin
    for bin in makemkvcon ffprobe; do
        command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found. Install MakeMKV (and 'sudo apt-get install -y ffmpeg' for ffprobe) first."
    done
    # HandBrakeCLI is only needed when encoding.
    if [[ "$ENCODE_AFTER_RIP" -eq 1 ]]; then
        command -v HandBrakeCLI >/dev/null 2>&1 || die "'HandBrakeCLI' not found, but encoding was requested. Install handbrake-cli or use -r."
    fi
}

check_encode_deps() {
    local bin
    for bin in HandBrakeCLI ffprobe; do
        command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found. Install handbrake-cli and ffmpeg first."
    done
}

# --- Media helpers -----------------------------------------------------------

# Whole-second duration of a media file (0 if unreadable).
media_duration() {
    local d
    d="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null || true)"
    d="${d%%.*}"
    [[ "$d" =~ ^[0-9]+$ ]] || d=0
    echo "$d"
}

# "H:MM:SS" (MakeMKV's format) -> seconds.
duration_to_secs() {
    local h=0 m=0 s=0
    IFS=: read -r h m s <<< "$1"
    echo $(( 10#${h:-0} * 3600 + 10#${m:-0} * 60 + 10#${s:-0} ))
}

secs_to_hms() {
    printf '%d:%02d:%02d' $(( $1 / 3600 )) $(( ($1 % 3600) / 60 )) $(( $1 % 60 ))
}

# validate_media FILE MIN_SECONDS — has video + audio streams and is not
# shorter than MIN_SECONDS (guards against truncated/failed rips and encodes).
validate_media() {
    local f="$1" min_secs="$2" streams dur
    streams="$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$f" 2>/dev/null || true)"
    grep -q '^video' <<< "$streams" || return 1
    grep -q '^audio' <<< "$streams" || return 1
    dur="$(media_duration "$f")"
    [[ "$dur" -ge "$min_secs" ]]
}

# --- Free-space guard --------------------------------------------------------
# Each in-flight rip/encode writes a reservation file (named by PID, holding
# the bytes it expects to use) into a shared dir. A new job only starts if the
# filesystem's free space, minus other live reservations, covers its own need
# plus MIN_FREE_GB headroom — so 8 drives starting at once can't collectively
# overfill the disk. The check-and-reserve runs under a flock so two jobs can't
# both claim the same space. Dead PIDs' reservations are discarded.
RESERVE_DIR="/tmp/.rip-disc-reservations"
RESERVATION_FILE=""

disc_size_bytes() {
    local b
    b="$(blockdev --getsize64 "$DEVICE" 2>/dev/null || echo 0)"
    # Can't read it? Assume a single-layer Blu-ray (25 GB) to stay safe.
    [[ "$b" =~ ^[0-9]+$ && "$b" -gt 0 ]] || b=$(( 25 * 1073741824 ))
    echo "$b"
}

reserved_bytes() {
    local total=0 f pid val
    for f in "$RESERVE_DIR"/*; do
        [[ -f "$f" ]] || continue
        pid="${f##*/}"
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            val="$(cat "$f" 2>/dev/null || echo 0)"
            [[ "$val" =~ ^[0-9]+$ ]] || val=0
            total=$(( total + val ))
        else
            rm -f "$f"
        fi
    done
    echo "$total"
}

# reserve_space NEED_BYTES DIR LABEL — returns 1 (with a warning) if short.
reserve_space() {
    local need="$1" dir="$2" label="$3"
    [[ "$MIN_FREE_GB" -gt 0 ]] || return 0

    mkdir -p "$RESERVE_DIR" "$dir"
    chmod 1777 "$RESERVE_DIR" 2>/dev/null || true

    local lockfd avail reserved headroom shortfall
    exec {lockfd}>"${RESERVE_DIR}/.lock"
    flock "$lockfd"

    avail="$(df -B1 --output=avail "$dir" 2>/dev/null | tail -n1 | tr -d ' ')"
    [[ "$avail" =~ ^[0-9]+$ ]] || avail=0
    reserved="$(reserved_bytes)"
    headroom=$(( MIN_FREE_GB * 1073741824 ))

    if (( avail - reserved < need + headroom )); then
        exec {lockfd}>&-
        shortfall=$(( (need + headroom - (avail - reserved) + 1073741823) / 1073741824 ))
        warn "Not enough free space for ${label}: need ~$(( need / 1073741824 )) GB + ${MIN_FREE_GB} GB headroom, have $(( avail / 1073741824 )) GB free ($(( reserved / 1073741824 )) GB reserved by other jobs) on the filesystem holding ${dir}. Short by ~${shortfall} GB."
        return 1
    fi

    echo "$need" > "${RESERVE_DIR}/$$"
    RESERVATION_FILE="${RESERVE_DIR}/$$"
    exec {lockfd}>&-
}

release_space() {
    if [[ -n "$RESERVATION_FILE" ]]; then
        rm -f "$RESERVATION_FILE"
        RESERVATION_FILE=""
    fi
}

# Per-process scratch dir on the SAME filesystem as the library (hidden, at
# the library root next to Movies/ and TV Shows/ so Jellyfin never scans it),
# so finished rips move into place with an atomic rename.
init_rip_tmp() {
    RIP_TMP="${RIP_ROOT}/.rip-tmp/$$"
    mkdir -p "$RIP_TMP"
}

# finalize_rip TMP_FILE FINAL_PATH MIN_SECONDS — verify, then move into the
# library with a .raw marker. On a failed check the file is renamed
# FINAL_PATH.failed (Jellyfin ignores it) and 1 is returned.
finalize_rip() {
    local tmp="$1" final="$2" min_secs="$3"
    if [[ -e "$final" || -e "${final}.raw" ]]; then
        warn "Refusing to overwrite existing file: $final (remove it or choose another name with -n)."
        return 1
    fi
    mkdir -p "$(dirname "$final")"
    if ! validate_media "$tmp" "$min_secs"; then
        mv -f -- "$tmp" "${final}.failed"
        warn "Rip failed verification (missing video/audio or shorter than ${min_secs}s): kept as ${final}.failed"
        return 1
    fi
    mv -- "$tmp" "$final"
    printf 'ripped=%s\n' "$(date -Is)" > "${final}.raw"
    RIPPED_FILES+=("$final")
    log "Ripped: $final"
}

# Scan title list via MakeMKV's robot output (-r) so we can show durations
# before committing to a rip order. TINFO codes: 7 = chapter count, 8 = duration.
scan_titles() {
    local src="dev:${DEVICE}"
    log "Scanning disc titles with MakeMKV..."
    local info
    info="$(makemkvcon -r info "$src" 2>/dev/null)" || die "MakeMKV title scan failed."

    declare -gA TITLE_DURATION
    declare -gA TITLE_CHAPTERS
    TITLE_IDS=()

    local line id value
    while IFS= read -r line; do
        if [[ "$line" =~ ^TINFO:([0-9]+),8,[0-9]+,\"([^\"]*)\"$ ]]; then
            id="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
            TITLE_DURATION["$id"]="$value"
            [[ " ${TITLE_IDS[*]:-} " == *" $id "* ]] || TITLE_IDS+=("$id")
        elif [[ "$line" =~ ^TINFO:([0-9]+),7,[0-9]+,\"([^\"]*)\"$ ]]; then
            id="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
            TITLE_CHAPTERS["$id"]="$value"
            [[ " ${TITLE_IDS[*]:-} " == *" $id "* ]] || TITLE_IDS+=("$id")
        fi
    done <<< "$info"

    [[ ${#TITLE_IDS[@]} -gt 0 ]] || die "No titles found on disc."

    IFS=$'\n' TITLE_IDS=($(printf '%s\n' "${TITLE_IDS[@]}" | sort -n))
    unset IFS
}

show_titles() {
    printf '\n  %-8s %-12s %-10s\n' "Title" "Duration" "Chapters"
    printf '  %-8s %-12s %-10s\n' "-----" "--------" "--------"
    local id
    for id in "${TITLE_IDS[@]}"; do
        printf '  %-8s %-12s %-10s\n' "$id" "${TITLE_DURATION[$id]:-?}" "${TITLE_CHAPTERS[$id]:-?}"
    done
}

# Interactively confirm which titles become which episodes, in what order.
# Populates the global SELECTED_TITLES array. In -y (non-interactive) mode,
# skips all prompts and uses every scanned title in disc order.
confirm_episode_selection() {
    show_titles

    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
        SELECTED_TITLES=("${TITLE_IDS[@]}")
    else
        echo
        echo "Enter the titles to rip as episodes, in episode order, space-separated"
        echo "(e.g. '0 1 2 4'), or press Enter to use all titles above in disc order."
        read -r -p "> " selection

        if [[ -z "$selection" ]]; then
            SELECTED_TITLES=("${TITLE_IDS[@]}")
        else
            # shellcheck disable=SC2206
            SELECTED_TITLES=($selection)
            local id valid
            for id in "${SELECTED_TITLES[@]}"; do
                valid=0
                for t in "${TITLE_IDS[@]}"; do [[ "$t" == "$id" ]] && valid=1 && break; done
                [[ "$valid" -eq 1 ]] || die "Title '$id' is not on this disc."
            done
        fi
    fi

    local season_padded
    season_padded="$(printf '%02d' "$SEASON")"

    echo
    echo "Episode mapping:"
    local ep=0 id
    for id in "${SELECTED_TITLES[@]}"; do
        ep=$((ep + 1))
        printf '  S%sE%02d  <-  Title %-4s (%s, %s chapters)\n' \
            "$season_padded" "$ep" "$id" "${TITLE_DURATION[$id]:-?}" "${TITLE_CHAPTERS[$id]:-?}"
    done

    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
        log "Non-interactive: proceeding with the mapping above."
        return
    fi

    echo
    read -r -p "Proceed with this mapping? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted by user — rerun and adjust the title selection."
}

DISC_EJECTED=0

# Ejects as soon as the rip is verified, never after encoding — once the rip
# is on local disk the drive isn't touched again, so a drive's turnaround is
# just its (fast, I/O-bound) rip time.
eject_disc() {
    [[ "$AUTO_EJECT" -eq 1 ]] || return 0
    [[ "$DISC_EJECTED" -eq 1 ]] && return 0

    if [[ "$MOUNTED_BY_US" -eq 1 ]]; then
        udisksctl unmount -b "$DEVICE" >/dev/null 2>&1 || true
        MOUNTED_BY_US=0
    fi

    log "Rip verified — ejecting $DEVICE..."
    if eject "$DEVICE" 2>/dev/null; then
        DISC_EJECTED=1
    else
        warn "Failed to eject $DEVICE — you may need to remove the disc manually."
    fi
}

# ---------------------------------------------------------------------------
# Encode concurrency limiter — a flock-based counting semaphore shared across
# every rip-disc.sh process on the machine (one lock file per slot in a
# shared /tmp directory), so it caps concurrent HandBrake encodes system-wide
# regardless of how many drives are ripping at once. MakeMKV's raw rip isn't
# gated by this — only the encode_one() call is.
# ---------------------------------------------------------------------------
ENCODE_SLOT_DIR="/tmp/.rip-disc-encode-slots"
ENCODE_SLOT_FD=""

acquire_encode_slot() {
    [[ "$MAX_ENCODES" -gt 0 ]] || return 0

    mkdir -p "$ENCODE_SLOT_DIR"
    chmod 1777 "$ENCODE_SLOT_DIR" 2>/dev/null || true

    local announced=0 i
    while true; do
        for (( i=0; i<MAX_ENCODES; i++ )); do
            exec {ENCODE_SLOT_FD}>"${ENCODE_SLOT_DIR}/slot-${i}.lock"
            if flock -n "$ENCODE_SLOT_FD"; then
                return 0
            fi
            exec {ENCODE_SLOT_FD}>&-
            ENCODE_SLOT_FD=""
        done
        if [[ "$announced" -eq 0 ]]; then
            log "All $MAX_ENCODES encode slot(s) busy with other drives — waiting for one to free up..."
            announced=1
        fi
        sleep 10
    done
}

release_encode_slot() {
    [[ -n "$ENCODE_SLOT_FD" ]] || return 0
    flock -u "$ENCODE_SLOT_FD" 2>/dev/null || true
    exec {ENCODE_SLOT_FD}>&- 2>/dev/null || true
    ENCODE_SLOT_FD=""
}

# Checked once, lazily, the first time encode_one() needs it.
HW_ENCODE_CHECKED=0

check_hw_encode() {
    [[ "$HW_ENCODE_CHECKED" -eq 1 ]] && return 0
    HW_ENCODE_CHECKED=1
    HandBrakeCLI --help 2>&1 | grep -q 'qsv_h265' || die \
        "Hardware encoding (-H) requested, but this HandBrakeCLI build has no qsv_h265 encoder. It needs to be built with Intel QSV/oneVPL support, and the Intel media driver installed — see setup.sh's optional Quick Sync step, or drop -H to use software x265."
}

# encode_one RAW OUT — runs HandBrakeCLI inside an encode slot and returns its
# exit status (so callers can handle a failed encode without aborting).
encode_one() {
    local raw="$1" out="$2" rc=0

    acquire_encode_slot
    if [[ "$HW_ENCODE" -eq 1 ]]; then
        check_hw_encode
        HandBrakeCLI \
            --input "$raw" \
            --output "$out" \
            --encoder qsv_h265 \
            --quality "$QUALITY" \
            --encoder-preset quality \
            --all-audio \
            --aencoder copy:ac3,copy:dts,av_aac \
            --audio-fallback av_aac \
            --all-subtitles \
            --subtitle-lang-list "$SUBTITLE_LANGS" \
            --subtitle-burned=none \
            --markers \
            --optimize \
            --format av_mkv || rc=$?
    else
        HandBrakeCLI \
            --input "$raw" \
            --output "$out" \
            --encoder x265 \
            --quality "$QUALITY" \
            --encoder-preset medium \
            --all-audio \
            --aencoder copy:ac3,copy:dts,av_aac \
            --audio-fallback av_aac \
            --all-subtitles \
            --subtitle-lang-list "$SUBTITLE_LANGS" \
            --subtitle-burned=none \
            --markers \
            --optimize \
            --format av_mkv \
            --two-pass \
            --turbo || rc=$?
    fi
    release_encode_slot
    return "$rc"
}

# encode_in_place FILE — encode a raw rip and replace it with the result.
# Writes to the scratch dir first, verifies the output, and only then swaps it
# over the raw file and removes the .raw marker. On any failure the raw file
# and marker are left untouched. Returns 1 on failure.
encode_in_place() {
    local f="$1" size src_dur out
    size="$(stat -c %s "$f")"
    src_dur="$(media_duration "$f")"

    if [[ -z "$RIP_TMP" ]]; then
        init_rip_tmp
    fi
    out="${RIP_TMP}/$(basename "$f")"

    if ! reserve_space $(( size / 2 )) "$RIP_ROOT" "encode of $(basename "$f")"; then
        return 1
    fi

    log "Encoding in place: $f"
    if encode_one "$f" "$out" && validate_media "$out" $(( src_dur * 98 / 100 )); then
        mv -f -- "$out" "$f"
        rm -f -- "${f}.raw"
        release_space
        log "Finished: $f (raw file replaced by the encode)"
        return 0
    fi

    warn "Encode failed or its output failed verification — keeping the raw file: $f"
    rm -f -- "$out"
    release_space
    return 1
}

# After a video rip: either encode what was ripped (-e / ENCODE_AFTER_RIP=1)
# or just point at how to encode later.
finish_video_job() {
    if [[ "$ENCODE_AFTER_RIP" -eq 1 ]]; then
        local f failed=0
        for f in "${RIPPED_FILES[@]}"; do
            encode_in_place "$f" || failed=$(( failed + 1 ))
        done
        [[ "$failed" -eq 0 ]] || die "${failed} encode(s) failed; the affected raw rip(s) were kept and are still marked .raw."
    else
        log "Rip-only: ${#RIPPED_FILES[@]} raw file(s) saved. Encode later with:  $0 -m encode"
    fi
}

# ---------------------------------------------------------------------------
# Movie mode
# ---------------------------------------------------------------------------
rip_movie() {
    check_video_deps

    local movie_name="$NAME"
    if [[ -z "$movie_name" ]]; then
        local disc_label
        disc_label="$(resolve_disc_label)"
        [[ -n "$disc_label" ]] || disc_label="Unknown_Title_$(date +%Y%m%d_%H%M%S)"

        if lookup_available; then
            log "Looking up '$disc_label' on TMDb..."
            if lookup_metadata movie "$disc_label"; then
                movie_name="$LOOKUP_TITLE"
                [[ -n "$LOOKUP_YEAR" ]] && movie_name="${movie_name} (${LOOKUP_YEAR})"
            fi
        fi

        if [[ -z "$movie_name" ]]; then
            if [[ "$NONINTERACTIVE" -eq 1 ]]; then
                movie_name="$disc_label"
                log "Non-interactive: using disc label '$movie_name' (no TMDb match)."
            else
                read -r -p "Enter movie name (blank to use disc label '$disc_label'): " movie_name
                [[ -n "$movie_name" ]] || movie_name="$disc_label"
            fi
        fi
    fi
    local safe_name
    safe_name="$(sanitize "$movie_name")"
    [[ -n "$safe_name" ]] || die "Resulting movie name is empty after sanitizing. Pass one explicitly with -n."

    local output_root="${RIP_ROOT}/Movies"
    local output_dir="${output_root}/${safe_name}"
    mkdir -p "$output_dir"

    log "Movie name : $safe_name"
    log "Output dir : $output_dir"

    if [[ -e "${output_dir}/${safe_name}.mkv" || -e "${output_dir}/${safe_name}.mkv.raw" ]]; then
        die "'${output_dir}/${safe_name}.mkv' already exists — not overwriting. Remove it or pass a different name with -n. (Disc left in the drive.)"
    fi

    init_rip_tmp
    reserve_space "$(disc_size_bytes)" "$RIP_ROOT" "rip of ${safe_name}" \
        || die "Not starting the rip — free up space or lower -f. (Disc left in the drive.)"

    local src="dev:${DEVICE}"
    log "Ripping main feature (longest title) with MakeMKV..."
    makemkvcon mkv "$src" 0 "$RIP_TMP" --minlength="$MINLENGTH" --noscan || {
        warn "Title 0 rip failed or wasn't the main feature; falling back to ripping all titles."
        rm -f "$RIP_TMP"/*.mkv
        makemkvcon mkv "$src" all "$RIP_TMP" --minlength="$MINLENGTH" --noscan
    }

    shopt -s nullglob
    local raw_files=("$RIP_TMP"/*.mkv)
    shopt -u nullglob
    [[ ${#raw_files[@]} -gt 0 ]] || die "MakeMKV produced no output files. Check the disc and drive."

    local index=0 raw
    for raw in "${raw_files[@]}"; do
        index=$((index + 1))
        local final_name="$safe_name"
        [[ ${#raw_files[@]} -gt 1 ]] && final_name="${safe_name} - Part ${index}"
        finalize_rip "$raw" "${output_dir}/${final_name}.mkv" "$MINLENGTH" \
            || die "Rip verification failed — disc left in the drive."
    done
    release_space

    eject_disc
    finish_video_job

    log "All done. Point Jellyfin's Movies library at: $output_root"
}

# ---------------------------------------------------------------------------
# TV mode
# ---------------------------------------------------------------------------
rip_tv() {
    check_video_deps

    local show_name="$NAME"
    if [[ -z "$show_name" ]]; then
        local disc_label
        disc_label="$(resolve_disc_label)"

        if [[ -n "$disc_label" ]] && lookup_available; then
            log "Looking up '$disc_label' on TMDb..."
            if lookup_metadata tv "$disc_label"; then
                show_name="$LOOKUP_TITLE"
                [[ -n "$LOOKUP_YEAR" ]] && show_name="${show_name} (${LOOKUP_YEAR})"
            fi
        fi

        if [[ -z "$show_name" ]]; then
            if [[ "$NONINTERACTIVE" -eq 1 ]]; then
                show_name="$disc_label"
                log "Non-interactive: using disc label '$show_name' (no TMDb match)."
            else
                read -r -p "Enter show name (blank to use disc label '$disc_label'): " show_name
                [[ -n "$show_name" ]] || show_name="$disc_label"
            fi
        fi
    fi
    [[ -n "$show_name" ]] || die "Could not determine show name from disc label. Pass one explicitly with -n."
    local safe_show
    safe_show="$(sanitize "$show_name")"
    [[ -n "$safe_show" ]] || die "Resulting show name is empty after sanitizing. Pass one explicitly with -n."

    local season_padded
    season_padded="$(printf '%02d' "$SEASON")"

    local output_root="${RIP_ROOT}/TV Shows"
    local season_dir="${output_root}/${safe_show}/Season ${season_padded}"
    mkdir -p "$season_dir"

    log "Show name  : $safe_show"
    log "Season     : $season_padded"
    log "Output dir : $season_dir"

    scan_titles
    confirm_episode_selection

    init_rip_tmp
    reserve_space "$(disc_size_bytes)" "$RIP_ROOT" "rip of ${safe_show} S${season_padded}" \
        || die "Not starting the rip — free up space or lower -f. (Disc left in the drive.)"

    # Rip every selected episode while the disc is in the drive (each title
    # into its own scratch subdir), verify it against the duration MakeMKV
    # reported, and move it into the library as it completes. Eject once all
    # are done — the disc isn't needed again.
    local src="dev:${DEVICE}"
    local ep=0 id
    for id in "${SELECTED_TITLES[@]}"; do
        ep=$((ep + 1))
        local ep_padded
        ep_padded="$(printf '%02d' "$ep")"
        local final_path="${season_dir}/${safe_show} - S${season_padded}E${ep_padded}.mkv"
        local rip_dir="${RIP_TMP}/title-${id}"
        mkdir -p "$rip_dir"

        log "Ripping title $id (-> S${season_padded}E${ep_padded}) with MakeMKV..."
        makemkvcon mkv "$src" "$id" "$rip_dir" --minlength=0 --noscan

        shopt -s nullglob
        local title_files=("$rip_dir"/*.mkv)
        shopt -u nullglob
        [[ ${#title_files[@]} -eq 1 ]] || die "Expected exactly one output file ripping title $id, found ${#title_files[@]}."

        local expected min_secs
        expected="$(duration_to_secs "${TITLE_DURATION[$id]:-0:00:00}")"
        min_secs=$(( expected * 95 / 100 ))
        finalize_rip "${title_files[0]}" "$final_path" "$min_secs" \
            || die "Rip verification failed for title $id — disc left in the drive."
    done
    release_space

    log "All ${#RIPPED_FILES[@]} episode(s) ripped and verified."
    eject_disc
    finish_video_job

    log "All done. Point Jellyfin's TV Shows library at: $output_root"
}

# ---------------------------------------------------------------------------
# Encode mode (-m encode): encode raw rips already in the library
# ---------------------------------------------------------------------------

# parse_selection "1 3 5-7" MAX — fills SELECTION with validated 1-based indexes.
parse_selection() {
    local input="${1//,/ }" max="$2" tok a b i
    SELECTION=()
    for tok in $input; do
        if [[ "$tok" == "all" ]]; then
            for (( i=1; i<=max; i++ )); do SELECTION+=("$i"); done
        elif [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
            (( a >= 1 && b <= max && a <= b )) || return 1
            for (( i=a; i<=b; i++ )); do SELECTION+=("$i"); done
        elif [[ "$tok" =~ ^[0-9]+$ ]]; then
            (( tok >= 1 && tok <= max )) || return 1
            SELECTION+=("$tok")
        else
            return 1
        fi
    done
    [[ ${#SELECTION[@]} -gt 0 ]]
}

encode_pending() {
    check_encode_deps
    [[ "$HW_ENCODE" -eq 1 ]] && check_hw_encode

    local files=() f marker
    if [[ ${#ENCODE_PATHS[@]} -gt 0 ]]; then
        for f in "${ENCODE_PATHS[@]}"; do
            [[ -f "$f" ]] || die "No such file: $f"
            [[ -f "${f}.raw" ]] || warn "$f has no .raw marker — encoding it anyway since you named it explicitly."
            files+=("$f")
        done
    else
        [[ -d "$RIP_ROOT" ]] || die "Library root '$RIP_ROOT' doesn't exist."
        while IFS= read -r -d '' marker; do
            f="${marker%.raw}"
            [[ -f "$f" ]] && files+=("$f")
        done < <(find "$RIP_ROOT" -path "${RIP_ROOT}/.rip-tmp" -prune -o -type f -name '*.mkv.raw' -print0 | sort -z)
    fi

    if [[ ${#files[@]} -eq 0 ]]; then
        log "Nothing to encode — no raw rips pending under $RIP_ROOT."
        return 0
    fi

    local encoder_desc="software x265 (CRF ${QUALITY})"
    [[ "$HW_ENCODE" -eq 1 ]] && encoder_desc="Intel Quick Sync qsv_h265 (quality ${QUALITY})"

    SELECTION=()
    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
        parse_selection all "${#files[@]}"
    else
        echo
        printf '  %-4s %-9s %-10s %s\n' "#" "Size" "Duration" "File"
        printf '  %-4s %-9s %-10s %s\n' "--" "----" "--------" "----"
        local i=0 size dur
        for f in "${files[@]}"; do
            i=$((i + 1))
            size="$(numfmt --to=iec --suffix=B "$(stat -c %s "$f")" 2>/dev/null || echo '?')"
            dur="$(secs_to_hms "$(media_duration "$f")")"
            printf '  %-4s %-9s %-10s %s\n' "$i" "$size" "$dur" "${f#"${RIP_ROOT}"/}"
        done
        echo
        echo "Encoder: ${encoder_desc}. Each raw file is replaced in place once its encode is verified."
        read -r -p "Select files to encode (e.g. '1 3 5-7' or 'all'; Enter to cancel): " reply
        [[ -n "$reply" ]] || { log "Cancelled."; return 0; }
        parse_selection "$reply" "${#files[@]}" || die "Invalid selection '$reply'."
        read -r -p "Encode ${#SELECTION[@]} file(s) with ${encoder_desc}? [y/N] " reply
        [[ "$reply" =~ ^[Yy]$ ]] || { log "Cancelled."; return 0; }
    fi

    local idx failed=0 done_count=0
    for idx in "${SELECTION[@]}"; do
        if encode_in_place "${files[$((idx - 1))]}"; then
            done_count=$((done_count + 1))
        else
            failed=$((failed + 1))
        fi
    done

    log "Encode finished: ${done_count} succeeded, ${failed} failed."
    [[ "$failed" -eq 0 ]] || exit 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [[ "$MODE" != "encode" ]]; then
    command -v blkid >/dev/null 2>&1 || die "'blkid' not found (should ship with util-linux)."
    if [[ "$AUTO_EJECT" -eq 1 ]]; then
        command -v eject >/dev/null 2>&1 || die "'eject' not found. Install with: sudo apt-get install -y eject (or pass -E to skip auto-eject)."
    fi
fi

RESOLVED_MODE="$MODE"
if [[ "$MODE" == "auto" ]]; then
    log "Detecting disc type in $DEVICE..."
    disc_type="$(detect_disc_type)"
    case "$disc_type" in
        music)
            RESOLVED_MODE="music"
            log "Detected: audio CD -> mode 'music'"
            ;;
        video)
            if [[ "$NONINTERACTIVE" -eq 1 ]]; then
                RESOLVED_MODE="movie"
                log "Detected: video disc -> mode 'movie' (non-interactive; pass -m tv explicitly for TV discs)"
            else
                echo
                read -r -p "Video disc detected. Is this a Movie or a TV show? [M/t] " mode_reply
                if [[ "$mode_reply" =~ ^[Tt]$ ]]; then
                    RESOLVED_MODE="tv"
                    read -r -p "Season number [${SEASON}]: " season_reply
                    [[ -n "$season_reply" ]] && SEASON="$season_reply"
                else
                    RESOLVED_MODE="movie"
                fi
                log "Mode: $RESOLVED_MODE"
            fi
            ;;
    esac
else
    if [[ "$MODE" == "movie" || "$MODE" == "tv" ]]; then
        # Still need to mount to sanity-check it's actually a video disc, and
        # to read the label if -n wasn't given.
        fs_type="$(blkid -o value -s TYPE "$DEVICE" 2>/dev/null || true)"
        [[ -n "$fs_type" ]] || die "No filesystem detected on $DEVICE — this doesn't look like a DVD-Video/Blu-ray disc."
    fi
fi

# Rip-only is the default. Interactive runs (no -y) that didn't pass -e/-r get
# asked per disc, defaulting to the configured ENCODE_AFTER_RIP value.
if [[ "$RESOLVED_MODE" == "movie" || "$RESOLVED_MODE" == "tv" ]]; then
    if [[ "$NONINTERACTIVE" -eq 0 && "$ENCODE_FLAG_SET" -eq 0 ]]; then
        if [[ "$ENCODE_AFTER_RIP" -eq 1 ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
        read -r -p "Encode after ripping? ${hint} " encode_reply
        if [[ -n "$encode_reply" ]]; then
            if [[ "$encode_reply" =~ ^[Yy] ]]; then ENCODE_AFTER_RIP=1; else ENCODE_AFTER_RIP=0; fi
        fi
    fi
    # Fail early (before ripping) if the chosen encoder can't run.
    if [[ "$ENCODE_AFTER_RIP" -eq 1 && "$HW_ENCODE" -eq 1 ]]; then
        check_hw_encode
    fi
fi

case "$RESOLVED_MODE" in
    encode) encode_pending ;;
    music) rip_music ;;
    movie) rip_movie ;;
    tv)    rip_tv ;;
esac
