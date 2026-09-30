#!/usr/bin/env bash
#
# rip-disc.sh — Rip a DVD (movie or TV) or audio CD into a Jellyfin-ready library.
#
# Auto-detects what's in the drive and routes to the right pipeline:
#   Audio CD    -> abcde (cdparanoia + FLAC + MusicBrainz tagging)
#   DVD, movie  -> MakeMKV (main feature) -> HandBrakeCLI (H.265 encode)
#   DVD, TV     -> MakeMKV title scan -> interactive confirmation of which
#                  titles map to which episodes -> HandBrakeCLI, named S01E01...
#
# Requirements (Ubuntu):
#   Run ./setup.sh to install everything automatically, or manually:
#     sudo apt-get install -y handbrake-cli abcde cdparanoia flac cd-discid genisoimage udisks2 jq
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
# Usage:
#   ./rip-disc.sh [-d /dev/sr0] [-m auto|movie|tv|music] [-n "Name"] [-s SEASON]
#                 [-o /path/to/library] [-q QUALITY] [-l MINLENGTH_SECONDS]
#                 [-L eng,fre,...] [-K TMDB_API_KEY] [-M] [-k]
#
#   -d DEVICE     Optical drive device (default: /dev/sr0)
#   -m MODE       auto (default) | movie | tv | music
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
#   -k            Keep temporary raw-rip files instead of deleting them after encode
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
KEEP_TEMP=0
WORKDIR="$(mktemp -d /tmp/discrip.XXXXXX)"

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
    if [[ "$KEEP_TEMP" -eq 0 && -d "$WORKDIR" ]]; then
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
while getopts "d:m:n:s:o:q:l:L:K:Mkh" opt; do
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
        k) KEEP_TEMP=1 ;;
        h) usage ;;
        *) usage ;;
    esac
done

[[ -b "$DEVICE" ]] || die "Device '$DEVICE' does not look like a block device. Pass the correct drive with -d."

case "$MODE" in
    auto|movie|tv|music) ;;
    *) die "Invalid mode '$MODE'. Use auto, movie, tv, or music." ;;
esac

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

    # Filesystem present (UDF/ISO9660) -> DVD-Video or data disc. Mount to check for VIDEO_TS.
    local udisk_out
    udisk_out="$(udisksctl mount -b "$DEVICE" 2>&1)" || die "Failed to mount $DEVICE: $udisk_out"
    MOUNT_POINT="$(echo "$udisk_out" | sed -n "s/.*at \(.*\)\.$/\1/p")"
    MOUNTED_BY_US=1

    if [[ -d "${MOUNT_POINT}/VIDEO_TS" ]]; then
        echo "video"
    else
        die "Disc at $DEVICE doesn't look like a DVD-Video or audio CD (no VIDEO_TS, no audio TOC). Data discs aren't supported by this script."
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
}

# ---------------------------------------------------------------------------
# Shared: MakeMKV raw extraction
# ---------------------------------------------------------------------------
check_video_deps() {
    for bin in makemkvcon HandBrakeCLI; do
        command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found. Install MakeMKV and HandBrake CLI first."
    done
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
# Populates the global SELECTED_TITLES array.
confirm_episode_selection() {
    show_titles

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

    echo
    read -r -p "Proceed with this mapping? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted by user — rerun and adjust the title selection."
}

encode_one() {
    local raw="$1" final_path="$2"
    HandBrakeCLI \
        --input "$raw" \
        --output "$final_path" \
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
        --turbo
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
            read -r -p "Enter movie name (blank to use disc label '$disc_label'): " movie_name
            [[ -n "$movie_name" ]] || movie_name="$disc_label"
        fi
    fi
    local safe_name
    safe_name="$(sanitize "$movie_name")"
    [[ -n "$safe_name" ]] || die "Resulting movie name is empty after sanitizing. Pass one explicitly with -n."

    local output_root="${OUTPUT_ROOT_OVERRIDE:-$VIDEO_OUTPUT_ROOT}/Movies"
    local output_dir="${output_root}/${safe_name}"
    mkdir -p "$output_dir"

    log "Movie name : $safe_name"
    log "Output dir : $output_dir"

    local src="dev:${DEVICE}"
    log "Ripping main feature (longest title) with MakeMKV..."
    makemkvcon mkv "$src" 0 "$WORKDIR" --minlength="$MINLENGTH" --noscan || {
        warn "Title 0 rip failed or wasn't the main feature; falling back to ripping all titles."
        makemkvcon mkv "$src" all "$WORKDIR" --minlength="$MINLENGTH" --noscan
    }

    shopt -s nullglob
    local raw_files=("$WORKDIR"/*.mkv)
    shopt -u nullglob
    [[ ${#raw_files[@]} -gt 0 ]] || die "MakeMKV produced no output files. Check the disc and drive."

    local index=0
    for raw in "${raw_files[@]}"; do
        index=$((index + 1))
        local final_name="$safe_name"
        [[ ${#raw_files[@]} -gt 1 ]] && final_name="${safe_name} - Part ${index}"
        local final_path="${output_dir}/${final_name}.mkv"

        log "Encoding: $(basename "$raw") -> ${final_name}.mkv"
        encode_one "$raw" "$final_path"
        log "Finished: $final_path"
    done

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
            read -r -p "Enter show name (blank to use disc label '$disc_label'): " show_name
            [[ -n "$show_name" ]] || show_name="$disc_label"
        fi
    fi
    [[ -n "$show_name" ]] || die "Could not determine show name from disc label. Pass one explicitly with -n."
    local safe_show
    safe_show="$(sanitize "$show_name")"
    [[ -n "$safe_show" ]] || die "Resulting show name is empty after sanitizing. Pass one explicitly with -n."

    local season_padded
    season_padded="$(printf '%02d' "$SEASON")"

    local output_root="${OUTPUT_ROOT_OVERRIDE:-$VIDEO_OUTPUT_ROOT}/TV Shows"
    local season_dir="${output_root}/${safe_show}/Season ${season_padded}"
    mkdir -p "$season_dir"

    log "Show name  : $safe_show"
    log "Season     : $season_padded"
    log "Output dir : $season_dir"

    scan_titles
    confirm_episode_selection

    local src="dev:${DEVICE}"
    local ep=0 id
    for id in "${SELECTED_TITLES[@]}"; do
        ep=$((ep + 1))
        local ep_padded
        ep_padded="$(printf '%02d' "$ep")"
        local final_path="${season_dir}/${safe_show} - S${season_padded}E${ep_padded}.mkv"

        log "Ripping title $id (-> S${season_padded}E${ep_padded}) with MakeMKV..."
        rm -f "$WORKDIR"/*.mkv 2>/dev/null || true
        makemkvcon mkv "$src" "$id" "$WORKDIR" --minlength=0 --noscan

        shopt -s nullglob
        local raw_files=("$WORKDIR"/*.mkv)
        shopt -u nullglob
        [[ ${#raw_files[@]} -eq 1 ]] || die "Expected exactly one output file ripping title $id, found ${#raw_files[@]}."

        log "Encoding: $(basename "${raw_files[0]}") -> $(basename "$final_path")"
        encode_one "${raw_files[0]}" "$final_path"
        log "Finished: $final_path"

        [[ "$KEEP_TEMP" -eq 1 ]] || rm -f "${raw_files[0]}"
    done

    log "All done. Point Jellyfin's TV Shows library at: $output_root"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
command -v blkid >/dev/null 2>&1 || die "'blkid' not found (should ship with util-linux)."

RESOLVED_MODE="$MODE"
if [[ "$MODE" == "auto" ]]; then
    log "Detecting disc type in $DEVICE..."
    disc_type="$(detect_disc_type)"
    case "$disc_type" in
        music) RESOLVED_MODE="music" ;;
        video) RESOLVED_MODE="movie" ;;
    esac
    log "Detected: $disc_type -> mode '$RESOLVED_MODE' (pass -m tv explicitly if this is a TV disc)"
else
    if [[ "$MODE" == "movie" || "$MODE" == "tv" ]]; then
        # Still need to mount to sanity-check it's actually a video disc, and
        # to read the label if -n wasn't given.
        fs_type="$(blkid -o value -s TYPE "$DEVICE" 2>/dev/null || true)"
        [[ -n "$fs_type" ]] || die "No filesystem detected on $DEVICE — this doesn't look like a DVD-Video disc."
    fi
fi

case "$RESOLVED_MODE" in
    music) rip_music ;;
    movie) rip_movie ;;
    tv)    rip_tv ;;
esac
