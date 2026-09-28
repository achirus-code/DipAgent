# DipAgent agent: REST API for the macOS app + the always-on bot engine.
#
# One image for both plain Docker and the Home Assistant add-on: the entrypoint reads the add-on options from
# /data/options.json when they exist and maps them to the same environment variables .env users set.
ARG TARGETARCH

# Home Assistant expects io.hass.arch per platform (amd64 / aarch64); buildx selects the stage via TARGETARCH.
FROM python:3.12-slim AS base-amd64
LABEL io.hass.arch="amd64"

FROM python:3.12-slim AS base-arm64
LABEL io.hass.arch="aarch64"

FROM base-${TARGETARCH} AS final
ARG BUILD_VERSION=dev
LABEL io.hass.version="${BUILD_VERSION}" \
      io.hass.type="addon" \
      io.hass.name="DipAgent" \
      io.hass.description="Trading bots for Revolut X, controlled from the DipAgent macOS menu bar app" \
      org.opencontainers.image.title="DipAgent" \
      org.opencontainers.image.source="https://github.com/achirus-code/DipAgent" \
      org.opencontainers.image.version="${BUILD_VERSION}" \
      org.opencontainers.image.licenses="MIT"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DATA_DIR=/data

WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

# Unprivileged runtime user; bots, trades, settings and the Revolut X key live in /data.
# The container starts as root only so the entrypoint can take over /data (Home Assistant mounts it root-owned)
# and then drops to this user before uvicorn starts. `docker run --user 10001` still works as before.
RUN useradd --system --uid 10001 dipagent && mkdir -p /data && chown dipagent /data
VOLUME ["/data"]
EXPOSE 3470

# start-period/start-interval: the add-on shows "Starting" until the first probe passes
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --start-interval=3s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:3470/api/health')"

# exactly one process: the engine must never run twice (it also holds a lock file in /data)
CMD ["python", "-m", "app.entrypoint"]
