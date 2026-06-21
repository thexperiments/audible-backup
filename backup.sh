#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------
# Audible Backup Script
# Downloads your Audible library and converts to M4B.
# Handles both AAX and AAXC (fallback) formats.
# -------------------------------------------------------

DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Audiobooks/raw}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Audiobooks/converted}"
AUDIBLE_CONFIG_DIR="${AUDIBLE_CONFIG_DIR:-/root/.audible}"

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

mkdir -p "$DOWNLOAD_DIR" "$OUTPUT_DIR"

# -------------------------------------------------------
# Download
# -------------------------------------------------------

log "Downloading Audible library (AAX with AAXC fallback)..."
audible download \
    --all \
    --aax-fallback \
    --cover \
    --chapter \
    --output-dir "$DOWNLOAD_DIR"

# -------------------------------------------------------
# Convert AAX files (single shared activation bytes)
# -------------------------------------------------------

aax_files=("$DOWNLOAD_DIR"/*.aax)
if [[ -e "${aax_files[0]}" ]]; then
    # Read activation bytes lazily — only needed if AAX files exist
    AUTHCODE=$(get_activation_bytes "$AUDIBLE_CONFIG_DIR")

    log "Converting ${#aax_files[@]} AAX file(s) to M4B..."
    for f in "${aax_files[@]}"; do
        title=$(basename "$f" .aax)
        out="$OUTPUT_DIR/${title}.m4b"
        if [[ -f "$out" ]]; then
            log "  Skipping (exists): $title"
            continue
        fi
        log "  Converting: $title"
        ffmpeg -activation_bytes "$AUTHCODE" \
               -i "$f" \
               -codec copy \
               "$out" \
               -loglevel warning \
        && log "  Done: $title" \
        || warn "  Failed: $title"
    done
else
    log "No AAX files found."
fi

# -------------------------------------------------------
# Convert AAXC files (per-file voucher key/iv)
# -------------------------------------------------------

aaxc_files=("$DOWNLOAD_DIR"/*.aaxc)
if [[ -e "${aaxc_files[0]}" ]]; then
    log "Converting ${#aaxc_files[@]} AAXC file(s) to M4B..."
    for f in "${aaxc_files[@]}"; do
        title=$(basename "$f" .aaxc)
        out="$OUTPUT_DIR/${title}.m4b"
        voucher="$DOWNLOAD_DIR/${title}.voucher"

        if [[ -f "$out" ]]; then
            log "  Skipping (exists): $title"
            continue
        fi

        if [[ ! -f "$voucher" ]]; then
            warn "  Skipping (no voucher file): $title"
            continue
        fi

        # Extract key and iv from the JSON voucher file
        key=$(python3 -c "import json,sys; v=json.load(open('$voucher')); print(v['content_license']['license_response']['key'])" 2>/dev/null) || { warn "  Failed to read key from voucher: $title"; continue; }
        iv=$(python3  -c "import json,sys; v=json.load(open('$voucher')); print(v['content_license']['license_response']['iv'])"  2>/dev/null) || { warn "  Failed to read iv from voucher: $title"; continue; }

        log "  Converting: $title"
        ffmpeg -audible_key "$key" \
               -audible_iv  "$iv" \
               -i "$f" \
               -codec copy \
               "$out" \
               -loglevel warning \
        && log "  Done: $title" \
        || warn "  Failed: $title"
    done
else
    log "No AAXC files found."
fi

# -------------------------------------------------------
# Summary
# -------------------------------------------------------

converted=(  "$OUTPUT_DIR"/*.m4b)
count=${#converted[@]}
[[ -e "${converted[0]}" ]] && log "Backup complete. $count book(s) in: $OUTPUT_DIR" \
                           || log "Backup complete. No output files found — check warnings above."
