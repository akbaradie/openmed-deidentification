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

echo ">> Building and pushing image via Cloud Build ($IMAGE)..."
# Not `gcloud builds submit --tag` -- that shortcut only looks for a
# Dockerfile at the build context root, and ours is at docker/Dockerfile.
# cloudbuild.yaml spells out the -f path explicitly instead.
gcloud builds submit --project "$PROJECT_ID" --config cloudbuild.yaml --substitutions="_IMAGE=${IMAGE}" .

echo ">> Deploying to Cloud Run..."
gcloud run deploy "$SERVICE_NAME" \
  --project "$PROJECT_ID" \
  --image "$IMAGE" \
  --region "$REGION" \
  --platform managed \
  --allow-unauthenticated \
  --execution-environment gen2 \
  --memory "$MEMORY" \
  --cpu "$CPU" \
  --concurrency "$CONCURRENCY" \
  --min-instances "$MIN_INSTANCES" \
  --max-instances "$MAX_INSTANCES" \
  --no-cpu-throttling \
  --add-volume name=hf-cache,type=cloud-storage,bucket="$BUCKET_NAME" \
  --add-volume-mount volume=hf-cache,mount-path=/data/hf-cache \
  --set-env-vars "OPENMED_PROFILE=prod,OPENMED_SERVICE_PRELOAD_MODELS=${MODEL},OPENMED_SERVICE_MAX_RESIDENT_MODELS=1,HF_HOME=/data/hf-cache" \
  --set-secrets "OPENMED_API_KEY=openmed-api-key:latest"

echo ">> Done. Service URL:"
gcloud run services describe "$SERVICE_NAME" --project "$PROJECT_ID" --region "$REGION" --format='value(status.url)'
