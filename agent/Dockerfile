# DipAgent agent: REST API for the macOS app + the always-on bot engine.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DATA_DIR=/data

WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

# run as an unprivileged user; bots, trades, settings and the Revolut X key live in /data
RUN useradd --system --uid 10001 dipagent && mkdir -p /data && chown dipagent /data
USER dipagent
VOLUME ["/data"]
EXPOSE 3470

HEALTHCHECK --interval=60s --timeout=5s CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:3470/api/health')"

# exactly one process: the engine must never run twice (it also holds a lock file in /data)
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "3470", "--proxy-headers"]
