#!/usr/bin/env bash
# Build and deploy the openmed-deidentification image to Cloud Run.
#
# Assumes scripts/setup_gcp.sh has already been run once (Artifact
# Registry repo and both secrets must already exist). This script itself
# has no long-lived credentials or secrets in it -- safe to call from a
# human's shell or from CI (.github/workflows/deploy.yml calls this
# directly after WIF auth).
#
# Model caching: the model is baked into the image at build time (see
# docker/Dockerfile + cloudbuild.yaml) rather than mounted from GCS at
# runtime -- no FUSE mount, no network read on cold start, just a local
# file already sitting in the image. HF_TOKEN only matters at *build*
# time now (cloudbuild.yaml pulls it from Secret Manager to avoid
# anonymous HF API rate limits during the bake-in download); this script
# no longer needs a GCS bucket or volume mount for it at all.
#
# HF_HUB_OFFLINE=1: without this, huggingface_hub still pings the Hub API
# at startup to check the local cache is fresh -- observed as an
# unauthenticated-request warning in Cloud Run logs even with the model
# fully baked in and OPENMED_SKIP_MODEL_VERIFY=1 set. That's a live network
# dependency (and rate-limit risk) cold start shouldn't have once the
# model's already on local disk, so this forces fully offline/local-only
# lookups at runtime. Must NOT be set during the build step -- the
# snapshot_download in docker/Dockerfile needs the network.
#
# TRANSFORMERS_OFFLINE / HF_HUB_DISABLE_TELEMETRY / TOKENIZERS_PARALLELISM:
# same spirit as HF_HUB_OFFLINE -- removing any remaining import-time
# network calls or fork-safety warning/thread-pool spin-up during the
# ~20s torch/transformers/openmed import phase, which measurement showed
# is the actual dominant cost of cold start (not model file location).
# Also runtime-only, same reasoning as HF_HUB_OFFLINE.
#
# OMP_NUM_THREADS=1 / MKL_NUM_THREADS=1: without these, torch's CPU
# intra-op parallelism defaults to using every available core for a
# SINGLE request's matrix ops -- with --cpu 2, one request already
# monopolizes both cores, so a second concurrent request just contends
# for the same threads instead of running in parallel. Confirmed
# empirically: 1 request took 74s, 2 concurrent took 138s (should be
# ~74s if truly parallel, ~148s if fully serial -- this was barely
# better than serial). Pinning each request to 1 thread trades slower
# single-request latency for genuine multi-request parallelism across
# --cpu's cores. Not yet re-measured after this change -- confirm with
# the same concurrent-vs-single comparison before trusting it.
#
# Auth: the app itself enforces X-API-Key (manage.py), so this deploys
# with --allow-unauthenticated to match the VM's auth model exactly. Add
# --no-allow-unauthenticated afterward if you also want Cloud Run IAM as a
# second layer.
#
# --cpu-throttling (request-based CPU, Cloud Run's default) instead of
# --no-cpu-throttling: CPU is only allocated while a request is actively
# being processed, not continuously. Switched deliberately from an earlier
# always-allocated setup. openmed's warm-pool idle-unload timers rely on
# background CPU time between requests to run promptly, which throttling
# can delay -- but with MAX_INSTANCES=1 and only one model ever preloaded
# (OPENMED_SERVICE_MAX_RESIDENT_MODELS=1), there's no second model
# competing for warm-pool slots, so nothing should actually trigger
# eviction regardless of timer timing. Revisit if a second model is ever
# added to this deployment. Cheaper this way -- no idle CPU billing.
#
# CONCURRENCY=256 with MAX_INSTANCES=1: this raises how many in-flight
# requests Cloud Run will queue onto the single instance, not how many run
# truly in parallel -- inference is CPU-bound and this is 2 vCPUs, so
# requests beyond what 2 CPUs can actually work on will queue and see
# worse tail latency under real concurrent load, not genuine 256-way
# parallelism. Worth confirming with `client/benchmark_rest.py
# --concurrency-levels ...` against this exact deployment before assuming
# it holds up under load.
#
# OPENMED_SKIP_MODEL_VERIFY: openmed 2.0.0's bundled manifest pins an
# expected checksum per model that is NOT a hash of the model weights --
# it's sha256(json({repo_id, sha: <HF commit>, released, siblings})), a
# hash over the HF repo's *commit metadata*. That means it changes on any
# new commit to the repo, including a pure README/model-card edit, even
# when the weight file itself never changes. Confirmed for
# OpenMed/privacy-filter-multilingual-v2: model.safetensors' own blob hash
# has been constant since its one upload (2026-05-06); the only commits
# since are two text-only doc edits on 2026-07-03, which is what tripped
# this. openmed 2.0.0's manifest was evidently frozen before those landed.
# No scoped allowlist/revision-pin exists in 2.0.0 -- this is the only
# override, and it's a global disable, not per-commit. Verified this isn't
# the model being swapped for something else before setting it; revisit
# (remove this) once openmed ships a release with an updated manifest or a
# less brittle (content-hash-based) verification scheme.
# --gpu: "0" is deliberate, not a no-op default. A GPU (nvidia-l4, 4 CPU/
# 16Gi) was attached to this service once via the Cloud Run console, and
# `gcloud run deploy` carries forward unspecified container resource
# settings from the latest revision -- simply omitting --gpu here did NOT
# clear it, and instead conflicted with this script's smaller --cpu/
# --memory values. Explicitly setting --gpu=0 is what actually removes it.
#
# NOTE: Cloud Run flags change over time -- double check `gcloud run deploy
# --help` against what's below before relying on this in a real pipeline.
set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID (gcloud config get-value project)}"
: "${REGION:=us-central1}"
: "${SERVICE_NAME:=openmed-deidentification}"
: "${REPO_NAME:=openmed}"
: "${MODEL:=OpenMed/privacy-filter-multilingual-v2}"
# 1Gi/1 CPU was tried and confirmed broken: passes the initial startup
# probe (model just barely fits at rest for one request) but OOM-kills
# under any real concurrent load (2+ overlapping model-handle
# constructions push memory past the limit) -- observed as a genuine
# crash loop in Cloud Run logs (OOM -> Killed -> AUTOSCALING restart -> OOM
# again). The weights alone are ~2.8GB at BF16; 4Gi is closer to the real
# floor once torch/transformers/request overhead is included. Don't drop
# below this without actually load-testing concurrent requests first, not
# just a single startup probe.
: "${MEMORY:=4Gi}"
: "${CPU:=2}"
: "${CONCURRENCY:=256}"
: "${MIN_INSTANCES:=0}"
: "${MAX_INSTANCES:=1}"

IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${SERVICE_NAME}:$(git rev-parse --short HEAD 2>/dev/null || date +%s)"
CACHE_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${SERVICE_NAME}:buildcache"

# openmed defaults OPENMED_SERVICE_TRUSTED_HOSTS to localhost/127.0.0.1 --
# Starlette's TrustedHostMiddleware 400s any request whose Host header
# doesn't match, which is every real client hitting the public Cloud Run
# URL. The .run.app URL is deterministic from project number + region;
# Cloud Run also serves an equivalent *.a.run.app short-hash alias that
# isn't knowable before the first deploy -- add it here (comma-separated)
# once you know it, or widen this if you're fronting the service with a
# custom domain.
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
TRUSTED_HOSTS="${SERVICE_NAME}-${PROJECT_NUMBER}.${REGION}.run.app,localhost,127.0.0.1"

echo ">> Building and pushing image via Cloud Build ($IMAGE)..."
# Not `gcloud builds submit --tag` -- that shortcut only looks for a
# Dockerfile at the build context root, and ours is at docker/Dockerfile.
# cloudbuild.yaml spells out the -f path explicitly instead.
gcloud builds submit --project "$PROJECT_ID" --config cloudbuild.yaml --substitutions="_IMAGE=${IMAGE},_CACHE_IMAGE=${CACHE_IMAGE}" .

echo ">> Deploying to Cloud Run..."
# Flags go through a --flags-file (YAML) instead of argv. Not just style --
# on Git Bash / MSYS (Windows), any CLI argument that looks like a Unix
# absolute path (e.g. mount-path=/data/hf-cache) gets silently rewritten
# into a Windows path before gcloud ever sees it, which then fails
# validation. A flags file is read directly by gcloud's Python code, never
# passed through a shell's argv, so it can't be mangled -- portable across
# bash, cmd.exe, and PowerShell alike (see `gcloud topic flags-file`).
FLAGS_FILE="$(mktemp)"
trap 'rm -f "$FLAGS_FILE"' EXIT

cat > "$FLAGS_FILE" <<EOF
--project: ${PROJECT_ID}
--image: ${IMAGE}
--region: ${REGION}
--platform: managed
--allow-unauthenticated:
--execution-environment: gen2
--memory: ${MEMORY}
--cpu: "${CPU}"
--gpu: "0"
--concurrency: ${CONCURRENCY}
--min-instances: ${MIN_INSTANCES}
--max-instances: ${MAX_INSTANCES}
--cpu-throttling:
--cpu-boost:
--clear-volumes:
--clear-volume-mounts:
--set-env-vars:
  OPENMED_PROFILE: prod
  OPENMED_SERVICE_PRELOAD_MODELS: "${MODEL}"
  OPENMED_SERVICE_MAX_RESIDENT_MODELS: "1"
  OPENMED_SKIP_MODEL_VERIFY: "1"
  OPENMED_SERVICE_TRUSTED_HOSTS: "${TRUSTED_HOSTS}"
  HF_HUB_OFFLINE: "1"
  TRANSFORMERS_OFFLINE: "1"
  HF_HUB_DISABLE_TELEMETRY: "1"
  TOKENIZERS_PARALLELISM: "false"
  OMP_NUM_THREADS: "1"
  MKL_NUM_THREADS: "1"
--set-secrets: OPENMED_API_KEY=openmed-api-key:latest
EOF

gcloud run deploy "$SERVICE_NAME" --flags-file="$FLAGS_FILE"

echo ">> Done. Service URL:"
gcloud run services describe "$SERVICE_NAME" --project "$PROJECT_ID" --region "$REGION" --format='value(status.url)'
