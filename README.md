# rip-disc.sh

![Last commit](https://img.shields.io/github/last-commit/iamnosferatu/dvd-ripper)

Rip a DVD/Blu-ray (movie or TV) or audio CD on Ubuntu into a Jellyfin-ready
media library. Auto-detects what's in the drive and routes to the right
pipeline:

| Disc type        | Pipeline                                                        | Output layout |
|-------------------|------------------------------------------------------------------|---------------|
| Audio CD          | `cdparanoia` + `flac` + MusicBrainz tagging via `abcde`          | `Music/Artist/Album/## - Track.flac` |
| DVD/Blu-ray, movie | MakeMKV (main feature), lossless; HandBrakeCLI encode is opt-in    | `Movies/Name (Year)/Name (Year).mkv` |
| DVD/Blu-ray, TV    | MakeMKV title scan → interactive episode confirmation; encode opt-in | `TV Shows/Show/Season 01/Show - S01E01.mkv` |

Auto-detection can reliably tell an audio CD from a DVD/Blu-ray video disc,
but it can't tell a movie disc from a TV disc (both look the same at the
filesystem level). So for a video disc, when run interactively (no `-y`),
it asks **"Is this a Movie or a TV show?"** (and, if TV, the season number)
right there before ripping starts — no need to know in advance and pass
`-m tv` yourself. Unattended/automated runs (`-y`) skip this prompt and
default to movie, since there's no one there to answer it — see
[Automatic ripping / multi-drive setup](#automatic-ripping--multi-drive-setup)
for how to reserve one drive that always asks.

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
              [-L eng,fre,...] [-K TMDB_API_KEY] [-M] [-y] [-E] [-j N] [-H]
              [-e|-r] [-f GB] [FILE...]
```

| Flag | Meaning | Default |
|------|---------|---------|
| `-d` | Optical drive device | `/dev/sr0` |
| `-m` | Mode: `auto`, `movie`, `tv`, `music`, or `encode` (encode raw rips already in the library — no disc needed) | `auto` |
| `-n` | Movie title (`"Name (Year)"`) or TV show name — skips TMDb lookup entirely | disc label / TMDb match |
| `-s` | Season number (TV mode only) | `1` |
| `-o` | Library root; `Movies/`, `TV Shows/`, `Music/` subfolders are created under it | `~/Videos/Jellyfin` (video) / `~/Music/Jellyfin` (audio) |
| `-q` | Encode quality (x265 CRF, or QSV ICQ with `-H`) — lower = higher quality/bigger file; only matters when encoding | `20` |
| `-l` | Minimum title length in seconds for MakeMKV to keep (movie mode) | `120` |
| `-L` | Comma-separated subtitle language codes to include, if present (soft subs only, never burned in) | `eng` |
| `-K` | TMDb API key (overrides the `TMDB_API_KEY` environment variable) | — |
| `-M` | Disable TMDb metadata lookup even if a key is available | off |
| `-y` | Non-interactive: auto-pick TMDb's top match and all titles in disc order instead of prompting | off |
| `-E` | Disable auto-eject on completion | off (auto-eject is **on** by default) |
| `-j` | Max simultaneous HandBrake encodes, system-wide across all drives (`0` = unlimited) | `2` |
| `-H` | Hardware-encode with Intel Quick Sync (`qsv_h265`) instead of software x265 — much faster, somewhat less efficient compression | off (software x265) |
| `-e` | Encode right after the rip | off (rip-only) unless `ENCODE_AFTER_RIP=1` in the config file |
| `-r` | Rip only — overrides `ENCODE_AFTER_RIP=1` from the config file | — |
| `-f` | Free-space headroom in GB to keep beyond each job's estimated need (`0` disables the free-space guard) | `10` |

### Rip now, encode later (default)

To save time, the default is **rip-only**: video discs are ripped by MakeMKV
straight to their final Jellyfin name — a lossless copy with every audio
track and subtitle — verified, and the disc is ejected. Nothing is
re-encoded unless you ask for it. The raw `.mkv` is playable in Jellyfin
immediately.

- **Marker files.** Each raw rip gets a small sidecar, `Name (Year).mkv.raw`,
  which is how the script knows it hasn't been encoded yet (Jellyfin ignores
  it).
- **Encode right after ripping:** pass `-e` for one run, or set a global
  default in `~/.config/rip-disc/config` (override the path with
  `RIP_DISC_CONFIG`; `setup.sh` offers to create it):
  ```bash
  ENCODE_AFTER_RIP=1   # 0 = rip-only (default)
  MIN_FREE_GB=10
  # QUALITY=20
  # HW_ENCODE=0
  ```
  The systemd automation reads this too (it runs as your user), so changing
  the file changes every drive's behaviour with no unit edits. `-e` / `-r`
  on the command line always win. Interactive runs with neither flag ask
  **"Encode after ripping?"** per disc (defaulting to the config value) —
  that includes the reserved sr0 console.
- **Encode later:** `./rip-disc.sh -m encode` needs no disc or drive. It
  scans the library for `.raw` markers and lists what's pending:
  ```
    #    Size      Duration   File
    --   ----      --------   ----
    1    5.8GiB    1:52:10    Movies/Blade Runner (1982)/Blade Runner (1982).mkv
    2    31.2GiB   2:03:44    Movies/Heat (1995)/Heat (1995).mkv

  Select files to encode (e.g. '1 3 5-7' or 'all'; Enter to cancel):
  ```
  Pick numbers, ranges or `all`, confirm, and it encodes them using your
  `-q`, `-H`, `-j` and `-L` settings. `./rip-disc.sh -m encode -y` encodes
  everything pending without asking (handy overnight), and you can pass
  explicit paths: `./rip-disc.sh -m encode "Movies/Heat (1995)/Heat (1995).mkv"`.
- **Safe replacement.** An encode is written to a hidden scratch folder
  (`<library>/.rip-tmp`, which Jellyfin never scans), checked with ffprobe
  (video + audio present, duration within 2% of the source), and only then
  moved over the raw file and the marker removed. If anything fails, the raw
  file and its marker are left exactly as they were.
- **Integrity check on every rip.** Before a rip is moved into the library it
  must have video and audio streams and not be shorter than expected (95% of
  the duration MakeMKV reported for TV titles; at least `-l` seconds for
  movies). A rip that fails is renamed `Name.mkv.failed` (ignored by
  Jellyfin) and the disc is **not** ejected, so a bad disc stays visibly
  stuck in its drive.
- **Never overwrites.** If `Name (Year).mkv` already exists the rip refuses
  to start (disc stays in the drive) — remove it or pick another name with `-n`.

### Free-space guard

With 8 drives ripping at once it's easy to fill the disk, so before each rip
the script reserves about the disc's size (read from the drive; 25 GB if it
can't tell) plus `-f` GB of headroom against the library's filesystem. The
reservation counts what other in-flight rips and encodes have already
claimed (shared via a lock in `/tmp`, so simultaneous starts can't
double-book the same free space). If there isn't room it refuses to start —
printing how short it is — and leaves the disc in the drive. Encodes reserve
about half the raw file's size for the new file. Set `-f 0` (or
`MIN_FREE_GB=0`) to turn the guard off. The estimate is deliberately
conservative: a DVD rips to well under its disc size, and a space check that
refuses early beats one that fails 40 GB into a Blu-ray.

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

Rip and then encode in one go (instead of the rip-only default):

```bash
./rip-disc.sh -e
```

Encode raw rips you pick later (software x265, or add `-H` for Quick Sync):

```bash
./rip-disc.sh -m encode
```

Allow up to 4 simultaneous encodes instead of the default 2 (e.g. on a
high-core-count machine):

```bash
./rip-disc.sh -j 4
```

Hardware-encode with Intel Quick Sync instead of software x265:

```bash
./rip-disc.sh -H
```

### Hardware encoding with Intel Quick Sync (`-H`)

By default, video is encoded with software x265 — this gives the best
compression efficiency (smallest file for a given quality) but is slow:
expect a rip to take noticeably longer than the movie's own runtime, even
on a decent CPU. If your machine has an Intel CPU with Quick Sync (most
Intel CPUs from roughly the last decade, including low-power T-series
chips), `-H` switches to hardware HEVC encoding instead, which is dramatically
faster — often close to real-time — at the cost of somewhat larger files
for the same visual quality (hardware encoders trade some compression
efficiency for speed).

Requirements:

- HandBrakeCLI needs to have been built with QSV/oneVPL support. Ubuntu's
  apt-packaged `handbrake-cli` doesn't always include this — `rip-disc.sh`
  checks for a `qsv_h265` encoder before using `-H` and refuses with a clear
  error if it isn't available, rather than silently falling back.
- The Intel media driver (`intel-media-va-driver-non-free`) needs to be
  installed, and your user needs access to `/dev/dri` (the `video`/`render`
  groups). `setup.sh` offers to handle both.

On a multi-drive machine, keep in mind Quick Sync is a single shared
hardware block per machine (unlike software encoding, which scales across
CPU cores) — running many `-H` encodes at once via a high `-j` value may
not actually go any faster than a lower one, since they're contending for
the same encode engine rather than separate cores.

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
  when the drive later ejects on its own) — except a drive you choose to
  reserve (see below).
- A **systemd service template** (`rip-disc@.service`) that the udev rule
  starts per drive — `rip-disc@sr1.service`, `rip-disc@sr2.service`, etc. —
  running `rip-disc.sh -d /dev/sr1 -y` as your user.

Because it runs with `-y`, there are no prompts: TMDb lookups auto-accept
the top match, TV-mode title selection auto-accepts disc order, and a
missing match just falls back to the disc's volume label. Auto-detection
still picks movie vs. music; without a human to answer "Movie or TV show?",
a video disc ripped through automation always defaults to **movie**.

### Reserving a drive for TV shows, Blu-ray, and other edge cases

Since automation can't ask "Movie or TV show?", `setup.sh` offers to
**reserve one drive** that's excluded from automation and instead runs an
always-on interactive console — the exact prompts you'd get running
`./rip-disc.sh` by hand, just permanently available without you having to
type anything to start it.

Say yes to "Reserve one drive for always-interactive ripping" when
`setup.sh` asks, pick the device (e.g. `/dev/sr0`) and a virtual terminal to
run it on (default `/dev/tty9`). This installs `rip-disc-console.service`,
which loops forever: wait for a disc in that drive → run `rip-disc.sh`
on it with full prompts (Movie or TV show?, season number, TMDb match,
etc.) → wait for the drive to empty again → repeat. Switch to that virtual
terminal (commonly `Ctrl+Alt+F9` for `tty9`, but check your system) any
time to see and answer its prompts; the rest of your desktop session is
unaffected. The other drives keep running fully automated as above.

This is the recommended way to dedicate one drive to TV box sets, Blu-ray
discs, or anything else you'd rather decide on a case-by-case basis, while
still running the rest of the machine completely hands-off.

The disc is ejected **as soon as its rip is verified — never after
encoding** (this is the default for every run, not just automated ones;
pass `-E` to disable it). With rip-only as the default there's no encode
step holding anything up at all: a drive's turnaround is just its rip time,
and the raw files wait in your library until you choose to encode them (or,
with `ENCODE_AFTER_RIP=1`, until a `-j` encode slot frees up).

Useful commands once it's installed:

```bash
# Watch a specific drive's rip in real time
journalctl -u rip-disc@sr1 -f

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

- Each drive's MakeMKV rip is fully independent and uncapped — it's disc
  I/O, not CPU, so all 8 drives can be reading discs at once with no
  contention.
- Rip-only is the default, so a rip never waits on the CPU. If you enable
  encoding (`-e` / `ENCODE_AFTER_RIP=1`) or run `-m encode`, HandBrake's x265
  encode is the CPU-heavy step and is gated by `-j` (default **2**
  simultaneous encodes, system-wide, regardless of how many drives or
  `-m encode` runs are active); extra jobs wait their turn for a slot.
  `setup.sh` asks for this limit when installing the automation (baked into
  each drive's systemd unit as `-j N`); change it later by editing the `-j`
  value in `/etc/systemd/system/rip-disc@.service` and running
  `sudo systemctl daemon-reload`. Pick a value based on your CPU — each
  x265 encode is itself multi-threaded, so "2" already uses a lot of
  cores; raise it only if you have cores to spare, or set `-j 0` to
  disable the limiter entirely.
- If a rip fails partway, the disc is **not** ejected, so a stalled drive
  is visibly still occupied (the same applies when the free-space guard or
  the integrity check refuses a rip) — check `journalctl -u rip-disc@sr1` to see why
  (or `sudo systemctl status rip-disc-console.service` for the reserved
  interactive drive, if you set one up).

### Walkthrough: loading all 8 drives at once

Say `/dev/sr0` has a TV series, `/dev/sr1`–`/dev/sr6` have movies, and
`/dev/sr7` has a music CD, and you've left the defaults alone (rip-only, no
`ENCODE_AFTER_RIP`). Do you need to start 8 scripts by hand, or can you set
it all off at once?

**If you reserved sr0 as the interactive drive when running `setup.sh`:**
load all 8 discs and close the trays — nothing to type for seven of them.

1. **Each drive starts itself.** For sr1–sr7, udev fires
   `rip-disc@srN.service` the instant media is readable. Before ripping,
   each job runs the free-space guard: it reserves about its disc's size
   (plus the 10 GB headroom) against the library disk, counting what the
   other drives have already claimed. If all eight fit, they all proceed;
   if the disk is short, the ones that don't fit refuse to start, log how
   many GB they're short, and **stay in their drives, not ejected,** so you can
   see which ones need attention.

2. **sr1–sr6 (movies)** auto-detect as DVD/Blu-ray → movie mode (the `-y`
   baked into the automated path skips every prompt), TMDb auto-picks the top
   match for the name, and MakeMKV rips the main feature into a scratch
   folder inside your library. ffprobe checks it (video + audio, not
   truncated), it's moved to `Movies/Name (Year)/Name (Year).mkv` with a
   `Name (Year).mkv.raw` marker beside it, and the tray **opens** — all eight
   rips run in parallel since it's pure disc I/O. There's no encode step to
   wait for, so each drive is free to reload the moment its tray opens.

3. **sr7 (music CD)** auto-detects as an audio CD → music mode. `abcde`
   rips to FLAC, tags it via MusicBrainz, and ejects — usually the fastest
   of the eight. Music is unaffected by the rip-only/encode distinction.

4. **sr0 (TV series)** is excluded from the udev rule, so it's the
   always-running `rip-disc-console.service` that notices the disc. Switch
   to its virtual terminal (e.g. `Ctrl+Alt+F9`) and you'll be asked:
   ```
   Video disc detected. Is this a Movie or a TV show? [M/t] t
   Season number [1]: 1
   Encode after ripping? [y/N]
   ```
   followed by the TMDb match picker and the episode-title mapping to
   confirm. Each episode is ripped, verified against the duration MakeMKV
   reported, and moved into `TV Shows/Show/Season 01/` as
   `Show - S01E01.mkv`, … with markers. The tray then opens and the console
   goes back to waiting for the next disc. (Answer `y` to "Encode after
   ripping?" if you want this one encoded straight away.)

**What you're left with:** a playable Jellyfin library of lossless raw
`.mkv` files, each with a `.raw` marker, a few minutes after loading the
trays — no CPU-heavy encoding has happened yet. Whenever you're ready:

```bash
./rip-disc.sh -m encode          # pick which raw files to encode, e.g. '1 3 5-7' or 'all'
./rip-disc.sh -m encode -H       # same, using Intel Quick Sync
./rip-disc.sh -m encode -y       # encode everything pending, unattended (e.g. overnight)
```

Each encode replaces its raw file in place only after the new file has been
verified, and the encodes share the same `-j` limit (default 2 at a time).
If you'd rather have encoding happen automatically, set `ENCODE_AFTER_RIP=1`
in `~/.config/rip-disc/config`: each drive then ejects as soon as its rip is
verified and encodes behind the shared `-j` limit, so a drive's tray still
opens after its rip, not after the encode.

**If something goes wrong** the drive tells you: a tray that never opens
means that drive's rip was refused or failed. Check why, e.g.
`journalctl -u rip-disc@sr3 -f` — typical causes are the free-space guard
(not enough room), a rip that failed verification (a `Name.mkv.failed` is
left in the library, ignored by Jellyfin), or a file that already exists.

Watch it all from one terminal:

```bash
journalctl -u 'rip-disc@*' -f              # live log across the automated drives
sudo systemctl status rip-disc-console.service   # the interactive console's state
systemctl list-units 'rip-disc@*'          # which automated instances are running/done/failed
```

**If you didn't reserve a drive (or haven't installed the automation at
all):** you're back to doing the TV drive by hand. Fire all 8 at once from
one shell, backgrounding each and redirecting logs so they don't interleave
on your terminal (rip-only is the default here too; add `-e` to encode
afterwards):

```bash
./rip-disc.sh -d /dev/sr0 -m tv -n "Show Name" -s 1 -y > /tmp/sr0.log 2>&1 &
for i in 1 2 3 4 5 6 7; do
    ./rip-disc.sh -d /dev/sr$i -y > /tmp/sr$i.log 2>&1 &
done
wait
```

`/dev/sr7` doesn't need `-m music` explicitly — auto-detect handles the
audio CD correctly on its own, same as the movie drives. `wait` blocks
your terminal until all 8 background jobs finish; drop it to get your
prompt back immediately and check progress with `tail -f /tmp/sr*.log`
instead. The free-space guard still applies, so simultaneous starts can't
overfill the disk. (If automation *is* installed but you just didn't
reserve a drive, stop the auto-triggered job for the TV drive first —
`sudo systemctl stop rip-disc@sr0.service` — before running it manually, so
the two don't race for the same disc.)

## Adding to Jellyfin

Point Jellyfin libraries at the output roots (or subfolders):

- **Movies** library → `~/Videos/Jellyfin/Movies`
- **TV Shows** library → `~/Videos/Jellyfin/TV Shows`
- **Music** library → `~/Music/Jellyfin`

Jellyfin's metadata matching works best when movie folders/files are named
`Movie Name (Year)` and TV episodes follow `Show - S01E01`, which is exactly
what this script produces by default.

## Notes

- Raw (rip-only) files keep everything MakeMKV extracts: all audio tracks,
  all subtitle languages, chapters. Encodes keep all audio tracks (AC3/DTS
  passthrough where possible, AAC fallback) and chapter markers; subtitles
  are soft (selectable) tracks — never burned in — filtered to the languages
  set by `-L` (default English only) at *encode* time.
- Raw rips are large (DVD ≈ 4–8 GB, Blu-ray ≈ 20–40 GB) and Jellyfin may need
  to transcode them for some clients — Blu-ray rips especially are worth
  encoding sooner rather than later.
- Two-pass x265 encoding is used for consistent quality; expect an encode to
  take significantly longer than the runtime of the disc (use `-H` to trade
  some compression efficiency for speed).
- Data discs (non-VIDEO_TS/BDMV, non-audio-CD) are not supported and the
  script will exit with an error.
- Commercial Blu-ray discs use AACS encryption, which MakeMKV decrypts
  using its own key database — this updates automatically as long as the
  machine has internet access when ripping. A very new release can
  occasionally outpace MakeMKV's key database; if a specific disc fails to
  rip, check for a MakeMKV update first.
- TMDb/MusicBrainz lookups need internet access. If you're ripping offline,
  pass `-M` (or just decline the prompts) to name things manually.
- Auto-eject on completion requires the `eject` package (installed by
  `setup.sh`); pass `-E` to disable it for a given run.
