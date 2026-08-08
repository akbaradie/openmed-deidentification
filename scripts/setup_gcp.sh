#!/usr/bin/env bash
# One-time GCP bootstrap. Run this once by hand (needs your own gcloud
# credentials with project-owner-ish permissions) before the first deploy,
# and again only if you rotate OPENMED_API_KEY or need to add another repo
# to the Workload Identity Pool. scripts/deploy_cloud_run.sh (run manually
# or from CI) assumes everything here already exists.
#
# Creates:
#   - Artifact Registry repo for the built image
#   - GCS bucket mounted at HF_HOME on Cloud Run (see deploy_cloud_run.sh)
#   - Secret Manager secrets holding OPENMED_API_KEY and HF_TOKEN (the
#     latter is required in practice, not just for gated models -- openmed
#     verifies checksums via the HF Hub API before downloading, and
#     anonymous API calls hit a much stricter rate limit that Cloud Run's
#     shared IP pool can trip on a single deploy)
#   - If SETUP_WIF=true (default): a dedicated deployer service account +
#     a Workload Identity Pool/OIDC provider trusting GitHub Actions,
#     scoped to one specific "owner/repo" -- for the .github/workflows/
#     deploy.yml path. Set SETUP_WIF=false if you're instead using Cloud
#     Run's own "Deploy continuously" / Developer Connect integration,
#     which authenticates itself and doesn't need any of this.
#
# NOTE: gcloud flags shift over time and none of this has been run
# end-to-end in this session -- sanity-check against current `gcloud`
# docs/help output before trusting it in a real pipeline.
set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID (gcloud config get-value project)}"
: "${REGION:=us-central1}"
: "${REPO_NAME:=openmed}"
: "${BUCKET_NAME:=${PROJECT_ID}-openmed-hf-cache}"
: "${OPENMED_API_KEY:?Set OPENMED_API_KEY -- stored in Secret Manager, never in GitHub}"
: "${HF_TOKEN:?Set HF_TOKEN -- a free read-scoped token from https://huggingface.co/settings/tokens, stored in Secret Manager}"
: "${SETUP_WIF:=true}"
if [ "$SETUP_WIF" = "true" ]; then
  : "${GITHUB_REPO:?Set GITHUB_REPO as owner/repo, e.g. akbaradie/openmed-deidentification (or set SETUP_WIF=false if using Developer Connect instead)}"
fi
: "${DEPLOYER_SA_NAME:=github-actions-deployer}"
: "${WIF_POOL_ID:=github-pool}"
: "${WIF_PROVIDER_ID:=github-provider}"

DEPLOYER_SA="${DEPLOYER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo ">> Enabling required APIs..."
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  secretmanager.googleapis.com \
  iamcredentials.googleapis.com \
  --project "$PROJECT_ID"

echo ">> Ensuring Artifact Registry repo exists..."
gcloud artifacts repositories describe "$REPO_NAME" --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1 || \
  gcloud artifacts repositories create "$REPO_NAME" --repository-format=docker --location="$REGION" --project="$PROJECT_ID"

echo ">> Ensuring HF cache bucket exists..."
gcloud storage buckets describe "gs://${BUCKET_NAME}" >/dev/null 2>&1 || \
  gcloud storage buckets create "gs://${BUCKET_NAME}" --location="$REGION" --uniform-bucket-level-access --project="$PROJECT_ID"

echo ">> Storing OPENMED_API_KEY and HF_TOKEN in Secret Manager..."
if gcloud secrets describe openmed-api-key --project="$PROJECT_ID" >/dev/null 2>&1; then
  printf '%s' "$OPENMED_API_KEY" | gcloud secrets versions add openmed-api-key --project="$PROJECT_ID" --data-file=-
else
  printf '%s' "$OPENMED_API_KEY" | gcloud secrets create openmed-api-key --project="$PROJECT_ID" --data-file=- --replication-policy=automatic
fi
if gcloud secrets describe openmed-hf-token --project="$PROJECT_ID" >/dev/null 2>&1; then
  printf '%s' "$HF_TOKEN" | gcloud secrets versions add openmed-hf-token --project="$PROJECT_ID" --data-file=-
else
  printf '%s' "$HF_TOKEN" | gcloud secrets create openmed-hf-token --project="$PROJECT_ID" --data-file=- --replication-policy=automatic
fi

# The *deployer* identity (above/below, WIF or your own gcloud auth) is who
# runs `gcloud run deploy` -- that's different from the identity Cloud Run
# actually runs the *container* as at runtime, which needs its own grant to
# read these secrets via --set-secrets. Defaults to the project's default
# compute service account unless deploy_cloud_run.sh is changed to pass
# --service-account with a dedicated runtime identity.
: "${RUNTIME_SA:=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')-compute@developer.gserviceaccount.com}"
echo ">> Granting the Cloud Run runtime service account (${RUNTIME_SA}) access to both secrets..."
for SECRET_NAME in openmed-api-key openmed-hf-token; do
  gcloud secrets add-iam-policy-binding "$SECRET_NAME" \
    --project="$PROJECT_ID" \
    --member="serviceAccount:${RUNTIME_SA}" \
    --role="roles/secretmanager.secretAccessor" \
    >/dev/null
done

if [ "$SETUP_WIF" != "true" ]; then
  cat <<EOF

>> Done (SETUP_WIF=false -- skipped the deployer service account and
   Workload Identity Federation setup). Artifact Registry repo, HF cache
   bucket, and the openmed-api-key secret are ready.

   If you're using Cloud Run's "Deploy continuously" / Developer Connect
   integration, finish that in the Cloud Run console -- it handles its own
   GitHub auth and doesn't need anything below this point.
EOF
  exit 0
fi

echo ">> Ensuring deployer service account exists..."
gcloud iam service-accounts describe "$DEPLOYER_SA" --project="$PROJECT_ID" >/dev/null 2>&1 || \
  gcloud iam service-accounts create "$DEPLOYER_SA_NAME" --project="$PROJECT_ID" --display-name="GitHub Actions Cloud Run deployer"

echo ">> Granting deployer roles (least-privilege for build + deploy)..."
for ROLE in roles/run.admin roles/artifactregistry.writer roles/iam.serviceAccountUser roles/cloudbuild.builds.editor roles/secretmanager.secretAccessor; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${DEPLOYER_SA}" \
    --role="$ROLE" \
    --condition=None \
    >/dev/null
done

echo ">> Ensuring Workload Identity Pool exists..."
gcloud iam workload-identity-pools describe "$WIF_POOL_ID" --project="$PROJECT_ID" --location="global" >/dev/null 2>&1 || \
  gcloud iam workload-identity-pools create "$WIF_POOL_ID" \
    --project="$PROJECT_ID" --location="global" --display-name="GitHub Actions Pool"

echo ">> Ensuring Workload Identity Provider exists (scoped to ${GITHUB_REPO})..."
gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER_ID" \
  --project="$PROJECT_ID" --location="global" --workload-identity-pool="$WIF_POOL_ID" >/dev/null 2>&1 || \
  gcloud iam workload-identity-pools providers create-oidc "$WIF_PROVIDER_ID" \
    --project="$PROJECT_ID" \
    --location="global" \
    --workload-identity-pool="$WIF_POOL_ID" \
    --display-name="GitHub Actions Provider" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
    --attribute-condition="assertion.repository == '${GITHUB_REPO}'"

WIF_POOL_RESOURCE=$(gcloud iam workload-identity-pools describe "$WIF_POOL_ID" \
  --project="$PROJECT_ID" --location="global" --format="value(name)")

echo ">> Allowing ${GITHUB_REPO} to impersonate the deployer service account..."
gcloud iam service-accounts add-iam-policy-binding "$DEPLOYER_SA" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/${WIF_POOL_RESOURCE}/attribute.repository/${GITHUB_REPO}" \
  >/dev/null

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
WIF_PROVIDER_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL_ID}/providers/${WIF_PROVIDER_ID}"

cat <<EOF

>> Done. Add these as GitHub Actions repo secrets (Settings > Secrets and
   variables > Actions) for .github/workflows/deploy.yml:

   WORKLOAD_IDENTITY_PROVIDER = ${WIF_PROVIDER_RESOURCE}
   DEPLOYER_SERVICE_ACCOUNT   = ${DEPLOYER_SA}

   And these as repo variables (same Settings page, "Variables" tab):

   GCP_PROJECT_ID = ${PROJECT_ID}
   GCP_REGION     = ${REGION}

   OPENMED_API_KEY itself never needs to go into GitHub -- it already
   lives in Secret Manager and Cloud Run reads it from there.
EOF
