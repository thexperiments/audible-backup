FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir audible-cli

WORKDIR /app
COPY backup.sh /app/backup.sh
RUN chmod +x /app/backup.sh

# Output directories — mount these as volumes from the host
VOLUME ["/output/raw", "/output/converted"]

# audible-cli stores auth config here — mount to persist between runs
VOLUME ["/root/.audible"]

ENV DOWNLOAD_DIR=/output/raw
ENV OUTPUT_DIR=/output/converted

ENTRYPOINT ["/app/backup.sh"]
