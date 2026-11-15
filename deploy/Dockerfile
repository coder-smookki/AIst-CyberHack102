
FROM node:24.22.3-bookworm-slim AS web

ENV NEXT_TELEMETRY_DISABLED=1
WORKDIR /web
COPY web/package.json web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY web/ ./
RUN npm run build

FROM python:3.11-slim-bookworm AS build

ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH

RUN pip install --index-url https://download.pytorch.org/whl/cpu torch torchvision

COPY requirements.txt /tmp/requirements.txt
RUN grep -v -E '^pytest' /tmp/requirements.txt > /tmp/runtime.txt \
    && pip install -r /tmp/runtime.txt

RUN version=$(pip show opencv-python | sed -n 's/^Version: //p') \
    && pip uninstall -y opencv-python opencv-python-headless \
    && pip install --no-deps "opencv-python-headless==${version}" \
    && find /opt/venv -name '__pycache__' -type d -prune -exec rm -rf {} +

FROM python:3.11-slim-bookworm

RUN apt-get update \
    && apt-get install -y --no-install-recommends fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --system --gid 10001 kst \
    && useradd --system --uid 10001 --gid kst --home-dir /app --shell /usr/sbin/nologin kst

COPY --from=build /opt/venv /opt/venv

ENV PATH=/opt/venv/bin:$PATH \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    KST_DB=/app/data/runtime/kst.db \
    FORWARDED_ALLOW_IPS=* \
    HF_HUB_OFFLINE=1

WORKDIR /app

COPY server ./server
COPY --from=web /web/out ./web/out
COPY cv ./cv
COPY models ./models
COPY data ./data

RUN mkdir -p /app/data/runtime \
    && chown -R kst:kst /app/data/runtime

USER kst

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD python -c "import json, urllib.request; json.load(urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4))['ok'] or exit(1)"

CMD ["python", "-m", "server", "--host", "0.0.0.0", "--port", "8000"]
