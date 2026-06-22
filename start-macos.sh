#!/usr/bin/env bash
# Start audible-backup using Apple's container tool (macOS 26+, Apple silicon).
# https://github.com/apple/container
#
# Usage:
#   ./start-macos.sh                        # run once and exit
#   SCHEDULE="0 2 * * 0" ./start-macos.sh  # stay alive on a cron schedule

set -euo pipefail

IMAGE="audible-backup:local"

# Directories on the host (edit these to suit your layout)
AUDIBLE_CONFIG_DIR="${AUDIBLE_CONFIG_DIR:-$HOME/.audible}"
RAW_DIR="${RAW_DIR:-$HOME/Audiobooks/raw}"
CONVERTED_DIR="${CONVERTED_DIR:-$HOME/Audiobooks/converted}"

# Optional cron schedule (leave unset to run once and exit)
# Example: SCHEDULE="0 2 * * 0" for every Sunday at 2 am
SCHEDULE="${SCHEDULE:-}"

# Ensure host directories exist before mounting
mkdir -p "$AUDIBLE_CONFIG_DIR" "$RAW_DIR" "$CONVERTED_DIR"

# Build the image from the local Dockerfile
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "Building image from ${SCRIPT_DIR}/Dockerfile..."
container build --arch arm64 -t "$IMAGE" "$SCRIPT_DIR"

# Build the argument list
args=(
  run --rm
  --arch arm64
  -v "${AUDIBLE_CONFIG_DIR}:/root/.audible"
  -v "${RAW_DIR}:/output/raw"
  -v "${CONVERTED_DIR}:/output/converted"
  -e "DOWNLOAD_DIR=/output/raw"
  -e "OUTPUT_DIR=/output/converted"
)

if [[ -n "$SCHEDULE" ]]; then
  args+=(-e "SCHEDULE=${SCHEDULE}")
  args+=(-d)   # detach when running on a schedule
  echo "Starting audible-backup on schedule \"${SCHEDULE}\" (detached)..."
else
  echo "Running audible-backup once (foreground)..."
fi

args+=("$IMAGE")

exec container "${args[@]}"
