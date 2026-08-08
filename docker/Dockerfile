FROM python:3.11-slim AS base

# Model/cache directory lives on a mounted volume; keep the image itself stateless.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    HF_HOME=/data/hf-cache \
    OPENMED_PROFILE=prod

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install -r requirements.txt

RUN useradd --create-home --uid 10001 openmed \
    && mkdir -p /data/hf-cache \
    && chown -R openmed:openmed /data /app

USER openmed

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/readyz || exit 1

# Single worker: the model warm pool is shared in-process; running multiple
# uvicorn workers would each load their own copy of the model. Scale out
# horizontally (more containers) instead of with --workers.
CMD ["uvicorn", "openmed.service.app:app", "--host", "0.0.0.0", "--port", "8080"]
