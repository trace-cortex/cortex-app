# Cortex backend (FastAPI engine) for Linux hosts. The macOS app is native and is NOT
# containerised; this image serves the HTTP/MCP API that the app, SDKs, browser extension
# and MCP clients talk to.
#
#   docker build -t cortex-backend .
#   docker run --rm -p 127.0.0.1:8766:8766 --env-file .env -v cortex-data:/data cortex-backend
#
# Design notes
# - Pinned dependencies from backend/requirements.lock.txt (same set as the local venv).
# - pysqlite3 is compiled against the distro's libsqlite3 so FTS5 + sqlite-vec extension
#   loading work regardless of the base image's bundled Python sqlite build.
# - Runs as a non-root user; data lives in /data (mount a volume); loopback-only publish is
#   the responsibility of the compose file / host (see docker-compose.yml).
FROM python:3.12-slim-bookworm AS build

ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PYTHONDONTWRITEBYTECODE=1
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libsqlite3-dev \
 && rm -rf /var/lib/apt/lists/*
COPY backend/requirements.lock.txt /tmp/requirements.lock.txt
RUN python -m venv /opt/venv \
 && /opt/venv/bin/pip install -r /tmp/requirements.lock.txt

FROM python:3.12-slim-bookworm
ENV PATH=/opt/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    CORTEX_HOST=0.0.0.0 \
    CORTEX_PORT=8766 \
    CORTEX_VAULT_PATH=/data/Cortex.vault \
    CORTEX_DB_PATH=/data/Cortex.vault/index.sqlite
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl libsqlite3-0 sqlite3 \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system cortex && useradd --system --gid cortex --home /srv/cortex --shell /usr/sbin/nologin cortex \
 && mkdir -p /srv/cortex /data && chown -R cortex:cortex /srv/cortex /data
COPY --from=build /opt/venv /opt/venv
WORKDIR /srv/cortex
COPY --chown=cortex:cortex backend ./backend
COPY --chown=cortex:cortex scripts ./scripts
COPY --chown=cortex:cortex spec ./spec
USER cortex
VOLUME ["/data"]
EXPOSE 8766
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${CORTEX_PORT}/health" >/dev/null || exit 1
CMD ["sh", "-c", "exec uvicorn backend.app.main:app --host \"$CORTEX_HOST\" --port \"$CORTEX_PORT\" --workers \"${CORTEX_UVICORN_WORKERS:-1}\" --proxy-headers --forwarded-allow-ips=\"${CORTEX_FORWARDED_ALLOW_IPS:-*}\""]
