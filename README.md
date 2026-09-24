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

## Usage

```bash
./rip-disc.sh [-d /dev/sr0] [-m auto|movie|tv|music] [-n "Name"] [-s SEASON]
              [-o /path/to/library] [-q QUALITY] [-l MINLENGTH_SECONDS]
              [-L eng,fre,...] [-k]
```

| Flag | Meaning | Default |
|------|---------|---------|
| `-d` | Optical drive device | `/dev/sr0` |
| `-m` | Mode: `auto`, `movie`, `tv`, `music` | `auto` |
| `-n` | Movie title (`"Name (Year)"`) or TV show name | disc label |
| `-s` | Season number (TV mode only) | `1` |
| `-o` | Library root; `Movies/`, `TV Shows/`, `Music/` subfolders are created under it | `~/Videos/Jellyfin` (video) / `~/Music/Jellyfin` (audio) |
| `-q` | x265 CRF for video encodes — lower = higher quality/bigger file | `20` |
| `-l` | Minimum title length in seconds for MakeMKV to keep (movie mode) | `120` |
| `-L` | Comma-separated subtitle language codes to include, if present (soft subs only, never burned in) | `eng` |
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
encoding start.

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
