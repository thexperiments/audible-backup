# audible-backup

Backs up your Audible library to DRM-free M4B files. Chapters and metadata are preserved. No re-encoding — fast lossless remux.

## Requirements

- Docker, **or** `ffmpeg` + `audible-cli` installed locally

## Image

Pre-built images are published to GHCR on every push to `main` and on version tags:

```
ghcr.io/thexperiments/audible-backup:main      # latest main
ghcr.io/thexperiments/audible-backup:v0.0.1    # pinned release
```

## First-time setup

```bash
# Authenticate with Audible (interactive, one-time)
audible quickstart

# Fetch and store activation bytes in the audible-cli config (needed for AAX files)
audible activation-bytes
```

The `~/.audible/` config directory only needs to be created once. The activation bytes are stored inside it automatically.

## Run locally

```bash
chmod +x backup.sh
./backup.sh
```

Output lands in `~/Audiobooks/converted/`. Re-running skips already-converted books.

## Run with Docker

```bash
# Pull pre-built image
docker pull ghcr.io/thexperiments/audible-backup:main

# Run once
docker run --rm \
  -v "$HOME/.audible:/root/.audible" \
  -v "$HOME/Audiobooks/raw:/output/raw" \
  -v "$HOME/Audiobooks/converted:/output/converted" \
  ghcr.io/thexperiments/audible-backup:main

# Run on a schedule (stays alive, re-runs every Sunday at 2am)
docker run -d --restart unless-stopped \
  -v "$HOME/.audible:/root/.audible" \
  -v "$HOME/Audiobooks/raw:/output/raw" \
  -v "$HOME/Audiobooks/converted:/output/converted" \
  -e SCHEDULE="0 2 * * 0" \
  ghcr.io/thexperiments/audible-backup:main
```

## Run on TrueNAS (Docker)

TrueNAS Scale 24.10+ uses Docker Compose. A `docker-compose.yml` is included.

**1. One-time auth setup — run this on any machine that has audible-cli:**

```bash
pip install audible-cli
audible quickstart          # interactive login
audible activation-bytes    # fetches and stores activation bytes in the config
```

Then copy `~/.audible/` to `/mnt/tank/audible/config/` on your NAS.

**2. Pull the image on the NAS** (via SSH) — no build step needed:

```bash
docker pull ghcr.io/thexperiments/audible-backup:main
```

**3. Start with Docker Compose** — the included `docker-compose.yml` runs the container persistently on a cron schedule:

```bash
docker compose up -d
```

The default schedule is every Sunday at 2am (`0 2 * * 0`). Edit the `SCHEDULE` value in `docker-compose.yml` to change it. Logs are available via:

```bash
docker compose logs -f audible-backup
```

> **Note:** Adjust the volume paths in `docker-compose.yml` to match your actual pool/dataset layout (default assumes `/mnt/tank/audible/`).

## Run on TrueNAS (Custom App UI)

If you want the container to appear and be manageable in the TrueNAS Apps UI, deploy it as a Custom App instead of using Docker Compose over SSH.

**Prerequisites:** Complete the one-time auth setup from step 1 of the Docker Compose section above — you need `~/.audible/` (with activation bytes stored inside) in place on your NAS before starting.

**1. Open the Custom App form:**

Apps → Discover Apps → Custom App (top-right button)

**2. Fill in the Application Name:**

```
audible-backup
```

**3. Under "Image Configuration", set the image:**

| Field | Value |
|---|---|
| Image Repository | `ghcr.io/thexperiments/audible-backup` |
| Image Tag | `main` |

**4. Under "Container Configuration", add environment variables:**

| Name | Value |
|---|---|
| `DOWNLOAD_DIR` | `/output/raw` |
| `OUTPUT_DIR` | `/output/converted` |
| `SCHEDULE` | `0 2 * * 0` |

Remove the `SCHEDULE` variable if you want the container to run once on start and exit rather than staying alive on a schedule.

**5. Under "Storage", add three host path volumes:**

| Host Path | Mount Path | Read Only |
|---|---|---|
| `/mnt/tank/audible/config` | `/root/.audible` | No |
| `/mnt/tank/audible/raw` | `/output/raw` | No |
| `/mnt/tank/audible/converted` | `/output/converted` | No |

Adjust the host paths to match your actual pool/dataset layout.

**6. Under "Restart Policy", select:**

```
Unless Stopped
```

**7. Click "Install".** The app will appear in your Apps list and can be started, stopped, and monitored from the UI.

> **Note:** Logs are accessible via the shell icon on the app's card, or by clicking the app name and selecting "Logs".

## Automate with cron (non-TrueNAS, without Docker)

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
| `DOWNLOAD_DIR` | `/output/raw` | Where raw AAX/AAXC files are saved |
| `OUTPUT_DIR` | `/output/converted` | Where M4B files are written |
| `AUDIBLE_CONFIG_DIR` | `/root/.audible` | Path to the audible-cli config directory |
| `SCHEDULE` | *(unset)* | Cron expression — if set, container stays alive and runs on schedule; if unset, runs once and exits |
