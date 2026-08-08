#!/usr/bin/env bash
# Build and deploy the openmed-deidentification image to Cloud Run.
#
# Assumes scripts/setup_gcp.sh has already been run once (Artifact
# Registry repo, HF cache bucket, and the openmed-api-key secret must
# already exist). This script itself has no long-lived credentials or
# secrets in it -- safe to call from a human's shell or from CI
# (.github/workflows/deploy.yml calls this directly after WIF auth).
#
# Model caching on Cloud Run: instances are ephemeral, so a plain local
# HF_HOME cache is wiped on every new instance/cold start. To get "download
# once, reuse after" on Cloud Run specifically, this mounts the bucket
# scripts/setup_gcp.sh created at HF_HOME via Cloud Run's native GCS FUSE
# volume mount -- the first cold start downloads the model into the
# bucket, every instance after (including new revisions) reads from it
# instead of Hugging Face. FUSE-backed reads are slower than local disk,
# but far faster than re-downloading multiple GB from HF on every cold
# start.
#
# Auth: the app itself enforces X-API-Key (manage.py), so this deploys
# with --allow-unauthenticated to match the VM's auth model exactly. Add
# --no-allow-unauthenticated afterward if you also want Cloud Run IAM as a
# second layer.
#
# HF_TOKEN: openmed verifies the model's checksums via the HF Hub API
# before downloading it. Anonymous (unauthenticated) HF API calls share a
# much stricter rate limit than authenticated ones -- Cloud Run's shared
# IP pool can hit that limit even for a single deploy, so this is required
# in practice, not just for gated/private models. Stored in Secret Manager
# as openmed-hf-token, same pattern as OPENMED_API_KEY (see setup_gcp.sh).
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
: "${BUCKET_NAME:=${PROJECT_ID}-openmed-hf-cache}"
: "${MODEL:=OpenMed/privacy-filter-multilingual-v2}"
: "${MEMORY:=4Gi}"
: "${CPU:=2}"
: "${CONCURRENCY:=8}"
: "${MIN_INSTANCES:=0}"
: "${MAX_INSTANCES:=5}"

IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${SERVICE_NAME}:$(git rev-parse --short HEAD 2>/dev/null || date +%s)"

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
gcloud builds submit --project "$PROJECT_ID" --config cloudbuild.yaml --substitutions="_IMAGE=${IMAGE}" .

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
--no-cpu-throttling:
--add-volume:
  name: hf-cache
  type: cloud-storage
  bucket: ${BUCKET_NAME}
--add-volume-mount:
  volume: hf-cache
  mount-path: /data/hf-cache
--set-env-vars:
  OPENMED_PROFILE: prod
  OPENMED_SERVICE_PRELOAD_MODELS: "${MODEL}"
  OPENMED_SERVICE_MAX_RESIDENT_MODELS: "1"
  HF_HOME: /data/hf-cache
  OPENMED_SKIP_MODEL_VERIFY: "1"
  OPENMED_SERVICE_TRUSTED_HOSTS: "${TRUSTED_HOSTS}"
--set-secrets: OPENMED_API_KEY=openmed-api-key:latest,HF_TOKEN=openmed-hf-token:latest
EOF

gcloud run deploy "$SERVICE_NAME" --flags-file="$FLAGS_FILE"

echo ">> Done. Service URL:"
gcloud run services describe "$SERVICE_NAME" --project "$PROJECT_ID" --region "$REGION" --format='value(status.url)'
