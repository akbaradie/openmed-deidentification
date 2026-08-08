# syntax=docker/dockerfile:1
# ^ required for the RUN --mount=type=secret step below (BuildKit only)

FROM ghcr.io/astral-sh/uv:latest AS uv

FROM python:3.11-slim AS base

# Model lives baked into the image at HF_HOME, not on a mounted volume --
# avoids the GCS FUSE mount + network read on every Cloud Run cold start.
# The tradeoff: every image build downloads it too, unless the layer below
# is served from cache (see cloudbuild.yaml's buildx registry cache).
#
# Cold-start measurement (see conversation/commit history) showed the
# ~25s Python/torch/transformers import phase dominates cold start, not
# model file location. UV_TORCH_BACKEND=cpu makes `uv pip install` resolve
# torch's CPU-only wheel instead of the default CUDA-enabled one -- this
# deployment has no GPU, so the CUDA build was pure import-time and
# image-size overhead (probing for/loading NVIDIA shared libraries this
# container will never use).
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_TORCH_BACKEND=cpu \
    HF_HOME=/data/hf-cache \
    OPENMED_PROFILE=prod \
    PORT=8080

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=uv /uv /uvx /usr/local/bin/

COPY requirements.txt .
RUN uv pip install --system --no-cache -r requirements.txt \
    # Precompile installed packages to .pyc at build time -- import-time
    # source compilation is part of the ~20s import phase that dominates
    # cold start (torch/transformers/openmed/fastapi). PYTHONDONTWRITEBYTECODE
    # above stops Python from writing .pyc at runtime (the non-root `openmed`
    # user wouldn't have permission to anyway) but doesn't stop it from
    # reading ones already baked in here, at the mtimes they were compiled
    # against -- safe since nothing touches these files again after this.
    #
    # `|| true`: compileall recurses into every .py file it finds, including
    # ones our app never imports -- e.g. torch/testing/_internal ships a
    # file using Python 3.12-only syntax (PEP 695 generics) that this
    # image's Python 3.11 can't parse. Best-effort optimization, not a
    # correctness requirement: a handful of unparseable, never-imported
    # files shouldn't fail the whole build.
    && (python -m compileall -q -j 0 /usr/local/lib/python3.11/site-packages || true)

# Bake OpenMed/privacy-filter-multilingual-v2 into the image. Deliberately
# NOT going through openmed's own downloader (which would also invoke its
# model-integrity check and require OPENMED_SKIP_MODEL_VERIFY at build
# time) -- huggingface_hub.snapshot_download populates the exact same
# on-disk HF cache layout under HF_HOME, so openmed finds it already
# present and complete at runtime and skips downloading. This step sits
# above COPY manage.py so app-code-only changes don't invalidate it and
# force a ~2.8GB re-download; cloudbuild.yaml's registry cache is what
# actually makes that cache hit persist across separate `gcloud builds
# submit` invocations (a plain `docker build` has no cache between runs).
#
# --mount=type=secret keeps HF_TOKEN out of the image's layer history --
# it's readable only for the duration of this RUN step.
RUN --mount=type=secret,id=hf_token \
    HF_TOKEN="$(cat /run/secrets/hf_token 2>/dev/null || true)" \
    python -c "\
import os; \
from huggingface_hub import snapshot_download; \
snapshot_download(repo_id='OpenMed/privacy-filter-multilingual-v2', token=os.environ.get('HF_TOKEN') or None)"

COPY manage.py .

RUN useradd --create-home --uid 10001 openmed \
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
