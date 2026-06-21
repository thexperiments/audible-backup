# audible-backup

Backs up your Audible library to DRM-free M4B files. Chapters and metadata are preserved. No re-encoding — fast lossless remux.

## Requirements

- Docker, **or** `ffmpeg` + `audible-cli` installed locally

## First-time setup

```bash
# Authenticate with Audible (interactive, one-time)
audible quickstart

# Save your activation bytes (needed for AAX files)
audible activation-bytes > ~/.authcode
```

The `~/.authcode` file and the `~/.audible/` config directory only need to be created once.

## Run locally

```bash
chmod +x backup.sh
./backup.sh
```

Output lands in `~/Audiobooks/converted/`. Re-running skips already-converted books.

## Run with Docker

```bash
# Build
docker build -t audible-backup .

# First run — mount your audible config and output directories
docker run --rm \
  -v "$HOME/.audible:/root/.audible" \
  -v "$HOME/.authcode:/root/.authcode:ro" \
  -v "$HOME/Audiobooks/raw:/output/raw" \
  -v "$HOME/Audiobooks/converted:/output/converted" \
  audible-backup
```

## Run on TrueNAS (Docker)

TrueNAS Scale 24.10+ uses Docker Compose. A `docker-compose.yml` is included.

**1. One-time auth setup — run this on any machine that has audible-cli:**

```bash
pip install audible-cli
audible quickstart          # interactive login
audible activation-bytes    # prints e.g. CAFED00D
```

Then copy `~/.audible/` to `/mnt/tank/audible/config/` on your NAS, and write your activation bytes:

```bash
echo "CAFED00D" > /mnt/tank/audible/config/authcode
```

**2. Build the image on the NAS** (via SSH):

```bash
cd /path/to/audible-backup
docker compose build
```

**3. Schedule with TrueNAS cron** (System Settings > Advanced > Cron Jobs):

- Command: `docker compose -f /path/to/audible-backup/docker-compose.yml run --rm audible-backup`
- Schedule: weekly or as needed
- Run as: `root`

Logs are visible under the job history, or append `>> /mnt/tank/audible/backup.log 2>&1` to the command.

> **Note:** Adjust the volume paths in `docker-compose.yml` to match your actual pool/dataset layout (default assumes `/mnt/tank/audible/`).

## Automate with cron (non-TrueNAS)

```
# Run every Sunday at 2am
0 2 * * 0 /path/to/backup.sh >> ~/audible-backup.log 2>&1
```

## How it works

1. `audible download --aax-fallback` downloads your full library. AAX is preferred; newer titles fall back to AAXC automatically.
2. AAX files are decrypted using your account-level activation bytes via ffmpeg.
3. AAXC files are decrypted using the per-file key/iv from the `.voucher` file audible-cli saves alongside each download.
4. All output is a lossless `-codec copy` remux — no quality loss, no re-encoding.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `DOWNLOAD_DIR` | `~/Audiobooks/raw` | Where raw AAX/AAXC files are saved |
| `OUTPUT_DIR` | `~/Audiobooks/converted` | Where M4B files are written |
| `AUTHCODE_FILE` | `~/.authcode` | Path to your activation bytes file |
