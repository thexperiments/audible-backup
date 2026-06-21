#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------
# Audible Backup Script
# Downloads your Audible library and converts to M4B.
# Handles both AAX and AAXC (fallback) formats.
# Conversion starts as soon as each file finishes
# downloading — no need to wait for the full library.
# -------------------------------------------------------

DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Audiobooks/raw}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Audiobooks/converted}"
AUDIBLE_CONFIG_DIR="${AUDIBLE_CONFIG_DIR:-/root/.audible}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"   # seconds between directory scans

# -------------------------------------------------------
# Helpers
# -------------------------------------------------------

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARN: $*" >&2; }
die()  { echo "[$(date '+%H:%M:%S')] ERROR: $*" >&2; exit 1; }

require() {
    command -v "$1" &>/dev/null || die "'$1' is not installed or not in PATH"
}

# Read activation_bytes from the audible-cli auth JSON file.
# audible-cli stores it there after running `audible activation-bytes`.
get_activation_bytes() {
    local config_dir="$1"
    local config_file="$config_dir/config.toml"

    if [[ ! -f "$config_file" ]]; then
        die "audible-cli config not found at $config_file. Run: audible quickstart"
    fi

    # Extract the primary profile name from config.toml
    local profile
    profile=$(python3 - "$config_file" <<'EOF'
import sys, re
path = sys.argv[1]
primary = None
in_app = False
for line in open(path):
    line = line.strip()
    if line == "[APP]":
        in_app = True
    elif line.startswith("["):
        in_app = False
    elif in_app:
        m = re.match(r'primary_profile\s*=\s*"([^"]+)"', line)
        if m:
            primary = m.group(1)
if primary:
    print(primary)
else:
    sys.exit(1)
EOF
) || die "Could not determine primary_profile from $config_file"

    # Derive the auth file name from the profile name (audible-cli default: <profile>.json)
    local auth_file="$config_dir/${profile}.json"
    if [[ ! -f "$auth_file" ]]; then
        die "Auth file not found: $auth_file"
    fi

    local ab
    ab=$(python3 -c "
import json, sys
data = json.load(open('$auth_file'))
ab = data.get('activation_bytes')
if not ab:
    sys.exit(1)
print(ab)
" 2>/dev/null) || die "activation_bytes not found in $auth_file. Run: audible activation-bytes"

    echo "$ab"
}

# -------------------------------------------------------
# Preflight checks
# -------------------------------------------------------

require audible
require ffmpeg
require ffprobe

# Build an output filename from embedded metadata: "Author - Title.m4b"
# Falls back to the input file stem if author or title tags are missing.
# Usage: make_output_name <input_file> <stem_fallback>
make_output_name() {
    local input="$1"
    local fallback="$2"

    local author title
    author=$(ffprobe -v quiet -show_entries format_tags=artist,author \
             -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null \
             | head -1 | sed 's/[[:space:]]*$//')
    title=$(ffprobe -v quiet -show_entries format_tags=title \
            -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null \
            | head -1 | sed 's/[[:space:]]*$//')

    if [[ -z "$author" || -z "$title" ]]; then
        echo "$fallback"
        return
    fi

    # Sanitize: strip characters not safe in filenames
    author=$(echo "$author" | tr -d '/:*?"<>|\\')
    title=$(echo  "$title"  | tr -d '/:*?"<>|\\')

    echo "${author} - ${title}"
}

# Convert a single AAX file. Requires AUTHCODE to be set in the environment.
# Usage: convert_aax <file>
convert_aax() {
    local f="$1"
    local stem title out
    stem=$(basename "$f" .aax)
    title=$(make_output_name "$f" "$stem")
    out="$OUTPUT_DIR/${title}.m4b"

    if [[ -f "$out" ]]; then
        log "  Skipping (exists): $title"
        return
    fi

    log "  Converting AAX: $title"
    ffmpeg -activation_bytes "$AUTHCODE" \
           -i "$f" \
           -codec copy \
           "$out" \
           -loglevel warning \
    && log "  Done: $title" \
    || warn "  Failed: $title"
}

# Convert a single AAXC file (reads key/iv from its .voucher sidecar).
# Usage: convert_aaxc <file>
convert_aaxc() {
    local f="$1"
    local stem title out voucher key iv
    stem=$(basename "$f" .aaxc)
    voucher="$DOWNLOAD_DIR/${stem}.voucher"

    if [[ ! -f "$voucher" ]]; then
        warn "  Skipping (no voucher file): $stem"
        return
    fi

    key=$(python3 -c "import json,sys; v=json.load(open('$voucher')); print(v['content_license']['license_response']['key'])" 2>/dev/null) || { warn "  Failed to read key from voucher: $stem"; return; }
    iv=$(python3  -c "import json,sys; v=json.load(open('$voucher')); print(v['content_license']['license_response']['iv'])"  2>/dev/null) || { warn "  Failed to read iv from voucher: $stem"; return; }

    title=$(make_output_name "$f" "$stem")
    out="$OUTPUT_DIR/${title}.m4b"

    if [[ -f "$out" ]]; then
        log "  Skipping (exists): $title"
        return
    fi

    log "  Converting AAXC: $title"
    ffmpeg -audible_key "$key" \
           -audible_iv  "$iv" \
           -i "$f" \
           -codec copy \
           "$out" \
           -loglevel warning \
    && log "  Done: $title" \
    || warn "  Failed: $title"
}

# Scan DOWNLOAD_DIR for any .aax/.aaxc files not yet converted and process them.
# Safe to call repeatedly — skips already-converted files.
convert_new_files() {
    local aax_files aaxc_files
    aax_files=("$DOWNLOAD_DIR"/*.aax)
    aaxc_files=("$DOWNLOAD_DIR"/*.aaxc)

    if [[ -e "${aax_files[0]}" ]]; then
        for f in "${aax_files[@]}"; do
            convert_aax "$f"
        done
    fi

    if [[ -e "${aaxc_files[0]}" ]]; then
        for f in "${aaxc_files[@]}"; do
            convert_aaxc "$f"
        done
    fi
}

mkdir -p "$DOWNLOAD_DIR" "$OUTPUT_DIR"

# -------------------------------------------------------
# Download (background) + convert (polling loop)
# -------------------------------------------------------

# Read activation bytes up front — needed as soon as the first AAX lands.
# This also validates the config early so we fail fast before any downloading.
log "Reading activation bytes from audible-cli config..."
AUTHCODE=$(get_activation_bytes "$AUDIBLE_CONFIG_DIR")

log "Starting download of Audible library in the background..."
audible download \
    --all \
    --aax-fallback \
    --cover \
    --chapter \
    --ignore-errors \
    --output-dir "$DOWNLOAD_DIR" &
DOWNLOAD_PID=$!

log "Polling for completed downloads every ${POLL_INTERVAL}s (PID: $DOWNLOAD_PID)..."
while kill -0 "$DOWNLOAD_PID" 2>/dev/null; do
    convert_new_files
    sleep "$POLL_INTERVAL"
done

# Wait for the download process to exit and capture its exit code.
wait "$DOWNLOAD_PID" || warn "audible download exited with a non-zero status — some titles may be missing."

# Final pass: catch any files that landed during the last sleep interval.
log "Download finished. Running final conversion pass..."
convert_new_files

# -------------------------------------------------------
# Summary
# -------------------------------------------------------

converted=("$OUTPUT_DIR"/*.m4b)
count=${#converted[@]}
[[ -e "${converted[0]}" ]] && log "Backup complete. $count book(s) in: $OUTPUT_DIR" \
                           || log "Backup complete. No output files found — check warnings above."
