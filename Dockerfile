FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
        cron \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir audible-cli

WORKDIR /app
COPY backup.sh /app/backup.sh
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/backup.sh /app/entrypoint.sh

# Output directories — mount these as volumes from the host
VOLUME ["/output/raw", "/output/converted"]

# audible-cli stores auth config here — mount to persist between runs
VOLUME ["/root/.audible"]

ENV DOWNLOAD_DIR=/output/raw
ENV OUTPUT_DIR=/output/converted
# Optional: set a cron schedule to run automatically, e.g. "0 2 * * 0"
# Leave unset to run once and exit.
ENV SCHEDULE=""
# Set to "false" to skip the immediate backup when SCHEDULE is set.
ENV RUN_ON_STARTUP=true

ENTRYPOINT ["/app/entrypoint.sh"]
