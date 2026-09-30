# rip-disc.sh

Rip a DVD (movie or TV) or audio CD on Ubuntu into a Jellyfin-ready media
library. Auto-detects what's in the drive and routes to the right pipeline:

| Disc type   | Pipeline                                                        | Output layout |
|-------------|------------------------------------------------------------------|---------------|
| Audio CD    | `cdparanoia` + `flac` + MusicBrainz tagging via `abcde`          | `Music/Artist/Album/## - Track.flac` |
| DVD, movie  | MakeMKV (main feature) → HandBrakeCLI (H.265/x265 encode)         | `Movies/Name (Year)/Name (Year).mkv` |
| DVD, TV     | MakeMKV title scan → interactive episode confirmation → HandBrakeCLI | `TV Shows/Show/Season 01/Show - S01E01.mkv` |

Auto-detection can reliably tell an audio CD from a DVD-Video disc, but it
can't tell a movie disc from a TV disc (both are just DVD-Video) — pass
`-m tv` explicitly for TV discs.

## Install (Ubuntu)

Run the setup script — it installs every dependency, offers to add the
community MakeMKV PPA, adds you to the `cdrom` group, and creates the
default library directories:

```bash
./setup.sh
```

Pass `-y` to accept all prompts non-interactively (still asks for your
`sudo` password for package installs):

```bash
./setup.sh -y
```

If you added yourself to the `cdrom` group for the first time, log out and
back in (or reboot) before ripping — group membership doesn't apply to
already-running sessions.

### Manual install

If you'd rather not run `setup.sh`:

```bash
sudo apt-get install -y handbrake-cli abcde cdparanoia flac cd-discid genisoimage udisks2
```

MakeMKV isn't in Ubuntu's official repos. Either add the community PPA:

```bash
sudo add-apt-repository ppa:heyarje/makemkv-beta
sudo apt-get update
sudo apt-get install -y makemkv-bin makemkv-oss
```

or download the current build directly from [makemkv.com](https://www.makemkv.com/download/)
(free during its beta license period) and follow its install instructions.

Verify everything is on your `PATH`:

```bash
command -v makemkvcon HandBrakeCLI abcde cdparanoia flac blkid udisksctl
```

`blkid` and `udisksctl` ship with Ubuntu by default (`util-linux` and
`udisks2`), so you shouldn't need to install those separately.

### Metadata lookup (optional but recommended)

By default, if you don't pass `-n`, movie and TV modes use the disc's raw
volume label as the name — which is often garbled (`BLADE_RUNNER_1982_WS`).
To get clean, accurate names instead, rip-disc.sh can search
[TMDb](https://www.themoviedb.org) (The Movie Database) using the disc label
as a query, show you the matching results, and let you confirm which one is
correct before anything is ripped.

This needs a free TMDb API key:

1. Create an account at [themoviedb.org](https://www.themoviedb.org/signup)
2. Generate a key at [themoviedb.org/settings/api](https://www.themoviedb.org/settings/api)
3. Either export it so `rip-disc.sh` picks it up automatically:
   ```bash
   echo 'export TMDB_API_KEY=your_key_here' >> ~/.bashrc
   source ~/.bashrc
   ```
   or pass it per run with `-K your_key_here`

`setup.sh` offers to save this for you interactively. Without a key (or with
`-M`), rip-disc.sh just falls back to prompting you for a name manually —
nothing breaks.

Music mode already gets database-driven naming for free: `abcde` queries
MusicBrainz for artist/album/track metadata on every audio CD rip.

## Usage

```bash
./rip-disc.sh [-d /dev/sr0] [-m auto|movie|tv|music] [-n "Name"] [-s SEASON]
              [-o /path/to/library] [-q QUALITY] [-l MINLENGTH_SECONDS]
              [-L eng,fre,...] [-K TMDB_API_KEY] [-M] [-y] [-E] [-k]
```

| Flag | Meaning | Default |
|------|---------|---------|
| `-d` | Optical drive device | `/dev/sr0` |
| `-m` | Mode: `auto`, `movie`, `tv`, `music` | `auto` |
| `-n` | Movie title (`"Name (Year)"`) or TV show name — skips TMDb lookup entirely | disc label / TMDb match |
| `-s` | Season number (TV mode only) | `1` |
| `-o` | Library root; `Movies/`, `TV Shows/`, `Music/` subfolders are created under it | `~/Videos/Jellyfin` (video) / `~/Music/Jellyfin` (audio) |
| `-q` | x265 CRF for video encodes — lower = higher quality/bigger file | `20` |
| `-l` | Minimum title length in seconds for MakeMKV to keep (movie mode) | `120` |
| `-L` | Comma-separated subtitle language codes to include, if present (soft subs only, never burned in) | `eng` |
| `-K` | TMDb API key (overrides the `TMDB_API_KEY` environment variable) | — |
| `-M` | Disable TMDb metadata lookup even if a key is available | off |
| `-y` | Non-interactive: auto-pick TMDb's top match and all titles in disc order instead of prompting | off |
| `-E` | Disable auto-eject on completion | off (auto-eject is **on** by default) |
| `-k` | Keep temporary raw MakeMKV rip files instead of deleting them | off |

### Examples

Auto-detect and rip whatever's in the drive (movie or music):

```bash
./rip-disc.sh
```

Rip a movie with a clean, Jellyfin-friendly name:

```bash
./rip-disc.sh -n "Blade Runner (1982)"
```

Rip season 2 of a TV show — you'll get an interactive title list to confirm
episode order before anything is encoded:

```bash
./rip-disc.sh -m tv -n "The Office" -s 2
```

Rip an audio CD to a custom music library location:

```bash
./rip-disc.sh -m music -o /mnt/media/Music
```

Skip TMDb lookup for this run and just prompt for a name manually:

```bash
./rip-disc.sh -M
```

Rip unattended (no prompts) and leave the disc in the drive afterward:

```bash
./rip-disc.sh -y -E
```

### TMDb title confirmation (movie/TV mode)

When `-n` isn't given and a TMDb API key is available, you'll see something
like this before ripping starts:

```
TMDb matches for 'BLADE_RUNNER_1982_WS':
  1) Blade Runner (1982)
  2) Blade Runner: The Final Cut (1982)
  0) None of these — enter the name manually
Pick a match [0-2]:
```

Choosing `0`, declining, or hitting a network error all fall back to a plain
manual-entry prompt — nothing fails hard.

### TV mode's interactive confirmation

MakeMKV's internal title order doesn't always match episode order, so TV
mode scans the disc first and shows you each title's duration and chapter
count:

```
  Title    Duration     Chapters
  -----    --------     --------
  0        0:22:14      8
  1        0:21:58      8
  2        0:21:47      6

Enter the titles to rip as episodes, in episode order, space-separated
(e.g. '0 1 2 4'), or press Enter to use all titles above in disc order.
>
```

After you pick (or accept the default disc order), it prints the resulting
episode mapping and asks for a final `y/N` confirmation before ripping and
encoding start. Pass `-y` to skip both prompts and just use every scanned
title in disc order (needed for unattended/automated runs — see below).

## Automatic ripping / multi-drive setup

For a dedicated ripping machine — e.g. several optical drives where you just
want to load a disc, walk away, and have it show up in the library — run
`./setup.sh` and say yes when it offers to install automatic ripping. This
sets up:

- A **udev rule** that detects when media is inserted into *any* `/dev/sr*`
  drive (it matches on the "media present" event, so it doesn't re-trigger
  when the drive later ejects on its own).
- A **systemd service template** (`rip-disc@.service`) that the udev rule
  starts per drive — `rip-disc@sr0.service`, `rip-disc@sr1.service`, etc. —
  running `rip-disc.sh -d /dev/sr0 -y` as your user.

Because it runs with `-y`, there are no prompts: TMDb lookups auto-accept
the top match, TV-mode title selection auto-accepts disc order, and a
missing match just falls back to the disc's volume label. Auto-detection
still picks movie vs. music; TV discs ripped through automation are treated
as movies unless you edit the systemd unit to add `-m tv -n "Show" -s N` for
a given drive/disc run.

When ripping finishes, the script **ejects the disc and opens the tray**
(this is now the default for every run, not just automated ones — pass `-E`
to keep the default off) so you can tell at a glance which drives are free
to load the next disc.

Useful commands once it's installed:

```bash
# Watch a specific drive's rip in real time
journalctl -u rip-disc@sr0 -f

# See what's currently running across all drives
systemctl list-units 'rip-disc@*'

# Change the saved TMDb key
sudo nano /etc/rip-disc.env

# Remove the automation entirely
sudo rm /etc/udev/rules.d/99-rip-disc.rules /etc/systemd/system/rip-disc@.service /etc/rip-disc.env
sudo udevadm control --reload-rules
sudo systemctl daemon-reload
```

A few things worth knowing for an 8-drive-style setup:

- Each drive's rip is fully independent — loading discs into multiple
  drives at once starts multiple concurrent rips.
- HandBrake's x265 encode is CPU-heavy; running many drives' encodes at
  once on one machine will contend for CPU and slow every rip down
  proportionally. There's no built-in concurrency limiter — if that
  matters for your hardware, consider a systemd `CPUQuota=` / slice on
  `rip-disc@.service`, or staggering how many drives you load at once.
- If a rip fails partway, the disc is **not** ejected, so a stalled drive
  is visibly still occupied — check `journalctl -u rip-disc@sr0` to see why.

## Adding to Jellyfin

Point Jellyfin libraries at the output roots (or subfolders):

- **Movies** library → `~/Videos/Jellyfin/Movies`
- **TV Shows** library → `~/Videos/Jellyfin/TV Shows`
- **Music** library → `~/Music/Jellyfin`

Jellyfin's metadata matching works best when movie folders/files are named
`Movie Name (Year)` and TV episodes follow `Show - S01E01`, which is exactly
what this script produces by default.

## Notes

- Video encodes keep all audio tracks (AC3/DTS passthrough where possible,
  AAC fallback), plus chapter markers. Subtitles are included as soft
  (selectable) tracks — never burned in — filtered to the languages set by
  `-L` (default English only); if the disc has no matching subtitle track,
  none are added and encoding proceeds normally.
- Two-pass x265 encoding is used for consistent quality; expect a rip to
  take significantly longer than the runtime of the disc.
- Data discs (non-VIDEO_TS, non-audio-CD) are not supported and the script
  will exit with an error.
- TMDb/MusicBrainz lookups need internet access. If you're ripping offline,
  pass `-M` (or just decline the prompts) to name things manually.
- Auto-eject on completion requires the `eject` package (installed by
  `setup.sh`); pass `-E` to disable it for a given run.
