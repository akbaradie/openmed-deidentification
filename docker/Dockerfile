FROM python:3.11-slim AS base

# Model cache lives at HF_HOME, meant to be a mounted volume (docker-compose
# named volume on a VM; a Cloud Storage FUSE volume mount on Cloud Run --
# see scripts/deploy_cloud_run.sh) so the model downloads once on first
# boot and every restart/cold start after that reuses the cached weights
# instead of re-fetching from Hugging Face.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    HF_HOME=/data/hf-cache \
    OPENMED_PROFILE=prod \
    PORT=8080

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY manage.py .

RUN useradd --create-home --uid 10001 openmed \
    && mkdir -p /data/hf-cache \
    && chown -R openmed:openmed /data /app

USER openmed

EXPOSE 8080

# Not used by Cloud Run (it has its own health probing) but load-bearing
# for the docker-compose/VM path, which gates the proxy on this.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${PORT}/readyz" || exit 1

# Shell-form CMD so $PORT expands at container start -- Cloud Run injects
# its own PORT value (not always 8080) and requires the container to listen
# on it. Single worker: the model warm pool is shared in-process, so
# running multiple uvicorn workers would each load their own copy of the
# model. Scale out horizontally (more container instances) instead of
# with --workers.
#
# manage:app wraps openmed.service.app with an API-key check (see
# manage.py) -- it re-exports the same routes, nothing reimplemented.
CMD uvicorn manage:app --host 0.0.0.0 --port ${PORT}
