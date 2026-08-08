# openmed-deidentification

Production deployment of the [OpenMed REST service](https://openmed.life/docs/rest-service/)
pinned to **`OpenMed/privacy-filter-multilingual-v2`**, with batch tooling for
processing large numbers of documents.

The service itself ships inside the `openmed` package
(`openmed.service.app`, FastAPI/Uvicorn) — every endpoint (`/analyze`,
`/pii/extract`, `/pii/deidentify`, `/jobs`, ...) is openmed's own, untouched.
This repo adds exactly two things around it:

1. **`manage.py`** — a thin auth shim. openmed has no built-in
   authentication; this re-exports its app with one addition, an
   `X-API-Key` check on every route except the health endpoints. Same
   enforcement everywhere it runs (host, Docker, Cloud Run), so auth
   behavior never depends on deployment target.
2. **Deployment plumbing** — a Dockerfile built for fast, cheap cold starts
   (Cloud Run's `$PORT` contract, model cache on a mounted volume so it
   downloads once and every restart after reuses it), Compose for a VM
   (with Caddy for TLS only — auth is already handled by `manage.py`),
   and a `gcloud` script for Cloud Run.

Plus batch clients and throughput benchmarks for processing many documents.

## Layout

```
manage.py                openmed.service.app + the X-API-Key check -- this is what actually runs
docker/Dockerfile           image: non-root, single worker, $PORT-aware, healthcheck
docker/Caddyfile             VM-only: TLS termination + proxy (no auth logic -- app owns that)
docker-compose.yml            openmed + Caddy, named volume for the HF cache (VM target)
scripts/setup_gcp.sh           one-time: Artifact Registry, HF cache bucket, secret, WIF trust for CI
scripts/deploy_cloud_run.sh   build + deploy to Cloud Run, GCS-FUSE-mounted HF cache (Cloud Run target)
cloudbuild.yaml                Cloud Build step pointing at docker/Dockerfile (used by deploy_cloud_run.sh)
.github/workflows/deploy.yml   CI/CD: deploy to Cloud Run on push to main, via Workload Identity Federation
.env.example                  copy to .env and fill in
scripts/run_local.sh          run manage.py directly on the host (no Docker)
scripts/run_colab.sh          install + start openmed.service.app raw + ngrok tunnel, for Colab scratch use
scripts/smoke_test.sh         health check + one authenticated deidentify call
client/batch_client.py         REST batch client (async, retries, concurrency)
client/batch_deidentify_local.py  in-process batch via openmed.BatchProcessor
client/benchmark_local.py       naive loop vs BatchProcessor, sweeps batch_size
client/benchmark_rest.py        sequential vs concurrent REST calls, sweeps concurrency
client/benchmark_common.py      shared synth-data / CSV / chart helpers
examples/sample_input.jsonl     sample batch input
```

`scripts/run_colab.sh` is the one exception that talks to
`openmed.service.app:app` directly, unauthenticated — it's a scratch/demo
path (see its own section below), not the deployable artifact. Everything
else runs `manage:app`.

## Why a single worker

The model warm pool lives in-process. Running multiple Uvicorn workers would
each load their own copy of `OpenMed/privacy-filter-multilingual-v2`,
multiplying memory use for no benefit. Scale horizontally instead: more
containers behind a load balancer on a VM, or `--max-instances` / Cloud
Run's own autoscaling on Cloud Run — never `--workers N` on one instance.

## Quickstart: Docker Compose (VM target)

```bash
cp .env.example .env
# edit .env: set OPENMED_API_KEY (required -- the app refuses to start
# without it), HF_TOKEN if the model is gated, and
# OPENMED_SERVICE_TRUSTED_HOSTS / OPENMED_SERVICE_CORS_ORIGINS for your domain

docker compose up -d --build
docker compose ps          # wait for openmed to report (healthy)

export OPENMED_API_KEY=...   # same value as in .env
bash scripts/smoke_test.sh http://127.0.0.1:8080
```

Requests must include `X-API-Key: <OPENMED_API_KEY>` — `manage.py` rejects
anything else with 401 before it reaches an openmed route (health endpoints
excluded). Put a real domain in `docker/Caddyfile` to get automatic TLS from
Let's Encrypt; Caddy's only job here is TLS, not auth.

## Quickstart: Cloud Run

Two scripts, run in order. `setup_gcp.sh` is one-time infrastructure
bootstrap; `deploy_cloud_run.sh` is the repeatable build+deploy, safe to
run by hand or from CI.

```bash
# once, by hand:
export PROJECT_ID=your-gcp-project
export OPENMED_API_KEY=...             # goes into Secret Manager, not GitHub
export GITHUB_REPO=you/openmed-deidentification   # for the WIF trust binding, see CI/CD below
bash scripts/setup_gcp.sh

# every deploy (redeploys, or what CI calls):
export PROJECT_ID=your-gcp-project
bash scripts/deploy_cloud_run.sh
```

What `setup_gcp.sh` does once: creates the Artifact Registry repo, the GCS
bucket mounted at `HF_HOME` (`/data/hf-cache`) via Cloud Run's native GCS
FUSE volume mount so the model downloads once on the first cold start and
every instance after — including new revisions — reads the cached weights
instead of hitting Hugging Face again, stores `OPENMED_API_KEY` in Secret
Manager, and sets up a Workload Identity Federation trust so GitHub Actions
can deploy without a stored key (see CI/CD below).

What `deploy_cloud_run.sh` does every time: builds the image via Cloud
Build (using `cloudbuild.yaml`, since `docker/Dockerfile` isn't at the
build context root), pushes to Artifact Registry, and deploys with
`--no-cpu-throttling` (CPU stays allocated between requests, needed for the
warm model pool and its idle-unload timers to behave correctly) and
`--allow-unauthenticated` (Cloud Run's own IAM gate is off; the app-level
`X-API-Key` check is what protects it, same as the VM).

Cold starts still happen whenever an instance scales up from zero — this
avoids re-downloading the model on each one, not the in-memory load into the
process itself. If you need zero cold starts entirely, set
`MIN_INSTANCES=1` before running `deploy_cloud_run.sh` (an always-on
instance costs more but skips scale-from-zero altogether).

`gcloud` flag names shift over time — this was written against the CLI's
current behavior but hasn't been run end-to-end in this session; sanity
-check `gcloud run deploy --help` / `gcloud iam workload-identity-pools
--help` against the scripts before trusting them in a real pipeline.

## CI/CD: deploy on push to `main`

`.github/workflows/deploy.yml` builds and deploys to Cloud Run on every
push to `main` (and via manual "Run workflow" dispatch). It's a thin
wrapper: checkout → authenticate to GCP → `bash scripts/deploy_cloud_run.sh`
→ smoke test the deployed URL. No new deploy logic lives in the workflow
file — it calls the same script you'd run by hand, so local and CI deploys
can't drift apart.

**Auth is keyless.** GitHub's own OIDC token is exchanged for short-lived
GCP credentials via Workload Identity Federation, scoped to this exact
`owner/repo` (the `--attribute-condition` in `scripts/setup_gcp.sh`) — no
service account JSON key sits in GitHub's secret store waiting to leak.

One-time setup, after running `scripts/setup_gcp.sh`:

1. It prints a `WORKLOAD_IDENTITY_PROVIDER` and `DEPLOYER_SERVICE_ACCOUNT`
   value — add both as **repo secrets** (Settings → Secrets and variables →
   Actions → Secrets).
2. Add `GCP_PROJECT_ID` and `GCP_REGION` as **repo variables** (same page,
   Variables tab) — non-sensitive, so they don't need to be secrets.
3. Optional: add a repo secret `OPENMED_SMOKE_TEST_API_KEY` (same value as
   `OPENMED_API_KEY`) if you want the workflow's smoke-test step to
   actually call the deployed service. This is the one place the raw key
   value has to be duplicated outside Secret Manager — skip step 3 (and
   delete the "Smoke test" step from the workflow) if you'd rather not do
   that, and rely on manually curling the service after deploy instead.

From then on, every push to `main` rebuilds and redeploys automatically.
This hasn't been run against a real GitHub repo/GCP project in this
session either — treat both scripts and the workflow as a well-reasoned
starting point to validate, not a proven pipeline.

## Quickstart: local (no Docker)

```bash
cp .env.example .env
bash scripts/run_local.sh
# in another shell:
export OPENMED_API_KEY=...   # same value as in .env
bash scripts/smoke_test.sh
```

## Quickstart: Google Colab

In a Colab cell:

```python
!git clone <this-repo-url> openmed-deidentification
%cd openmed-deidentification
import os
os.environ["NGROK_AUTH_TOKEN"] = "..."   # from dashboard.ngrok.com
# optional: os.environ["NGROK_HOSTNAME"] = "your-reserved-domain.ngrok-free.dev"
!bash scripts/run_colab.sh
```

This installs `openmed[hf,service]` + `pyngrok`, starts the service in the
background, waits for `/readyz`, opens the tunnel, and writes the public URL
to `openmed_tunnel_url.txt`. Logs go to `openmed_service.log`; stop the
server with `kill $(cat openmed_service.pid)`.

If you don't reserve an ngrok domain (`NGROK_HOSTNAME`), the script relaxes
`OPENMED_SERVICE_TRUSTED_HOSTS` to `*` since the random tunnel hostname can't
be known ahead of time — that relaxation is fine for a scratch Colab session
but should not be carried into a real deployment. Put an `X-API-Key` proxy
(or at minimum a strong shared secret checked in your own client) in front
of anything reachable from the public internet.

## Single request examples

```bash
curl -sS -X POST "$BASE_URL/pii/deidentify" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $OPENMED_API_KEY" \
  -d '{
    "text": "Patient Jordan Ramirez, MRN 4482910, called from 555-0147.",
    "method": "mask",
    "lang": "en",
    "model_name": "OpenMed/privacy-filter-multilingual-v2"
  }'
```

```python
from openmed.service.client import OpenMedClient

with OpenMedClient(
    "http://127.0.0.1:8080",
    timeout=310.0,
    headers={"X-API-Key": "..."},   # check OpenMedClient's signature for this repo's
                                     # openmed version -- the documented recipe doesn't
                                     # show a headers/api_key kwarg, so this may need to
                                     # go through an httpx.Client default_headers instead
) as client:
    redacted = client.deidentify(
        "Patient Jordan Ramirez was admitted on 2026-01-02.",
        method="mask",
        model_name="OpenMed/privacy-filter-multilingual-v2",
    )
    print(redacted.deidentified_text)
```

## Batch processing

Two options depending on where you're running from.

### Remote / REST (no openmed install needed)

```bash
pip install -r client/requirements.txt

python client/batch_client.py \
  --base-url http://127.0.0.1:8080 \
  --api-key "$OPENMED_API_KEY" \
  --input examples/sample_input.jsonl \
  --output results.jsonl \
  --model OpenMed/privacy-filter-multilingual-v2 \
  --method mask \
  --concurrency 8
```

Bounded concurrency, retries with exponential backoff on 429/5xx, and a
JSONL output written incrementally as results complete. Input is JSONL of
`{"id": ..., "text": ...}` per line.

### In-process (openmed installed locally / in Colab)

Faster for large corpora, and supports crash-safe checkpoint/resume:

```bash
python client/batch_deidentify_local.py \
  --input examples/sample_input.jsonl \
  --output results.json \
  --flat-output results.jsonl \
  --model OpenMed/privacy-filter-multilingual-v2 \
  --method mask \
  --checkpoint-interval 25
```

If it's interrupted, rerun with `--resume` to continue from the last
checkpoint instead of reprocessing everything.

For very large corpora (millions of documents), see OpenMed's
[distributed shard runner](https://openmed.life/docs/batch-processing/)
(`openmed batch-run start --shards N --workers M`) — same underlying
`BatchProcessor`, but splits work across shards with a durable manifest.

## Benchmarking: batch vs non-batch, and finding the sweet spot

Yes, this is directly measurable, at two levels:

- **In-process**: `openmed.BatchProcessor` (which pads/groups items for the
  model forward pass) vs calling `deidentify()` one at a time in a loop.
- **Over REST**: sequential requests (`concurrency=1`, so the server's
  dynamic batching never has anything to coalesce) vs concurrent requests at
  increasing levels, which is what actually engages
  `OPENMED_SERVICE_BATCHING_ENABLED` server-side.

Both scripts sweep a list of sizes, time each with a warm model (a throwaway
warm-up call happens first so cold-start doesn't skew results), and report
throughput (items/sec) plus a "sweet spot" — the smallest size within 5% of
peak throughput, since larger batches past that point cost more memory and
worse tail latency for negligible extra gain. Each writes a CSV, prints a
table, and (if `matplotlib` is installed) a PNG chart.

```bash
pip install -r client/requirements.txt

# In-process: needs openmed installed locally (e.g. in Colab)
python client/benchmark_local.py \
  --num-samples 200 \
  --batch-sizes 1,2,4,8,16,32,64 \
  --model OpenMed/privacy-filter-multilingual-v2 \
  --out-prefix bench_local

# Over REST: point at a running, already-warmed-up service
python client/benchmark_rest.py \
  --base-url http://127.0.0.1:8080 \
  --api-key "$OPENMED_API_KEY" \
  --num-samples 200 \
  --concurrency-levels 1,2,4,8,16,32 \
  --model OpenMed/privacy-filter-multilingual-v2 \
  --out-prefix bench_rest
```

Notes on getting a clean read:
- Run on the same hardware/instance you'll deploy on — GPU vs CPU and core
  count change where the sweet spot lands.
- `--num-samples` should be comfortably larger than the biggest size in the
  sweep, or the last (partial) batch dominates the timing.
- For the REST benchmark, synthetic texts are given a unique nonce per item
  (see `benchmark_common.load_or_synthesize_texts`) so request coalescing
  doesn't dedupe them and understate real concurrent load.
- Repeat with `--repeats N` (local script only) to smooth out noise; the
  best of N runs per size is kept.

## Configuration reference

All knobs live in `.env.example`. The ones that matter most for this
deployment:

| Variable | Purpose |
|---|---|
| `OPENMED_SERVICE_PRELOAD_MODELS` | pinned to `OpenMed/privacy-filter-multilingual-v2` — loaded warm at startup, no cold-start on first request |
| `OPENMED_SERVICE_MAX_RESIDENT_MODELS` | set to `1` since this deployment only serves one model |
| `OPENMED_SERVICE_BATCHING_ENABLED` / `_BATCH_MAX_SIZE` / `_BATCH_MAX_WAIT_MS` | dynamic request batching for concurrent `/pii/extract` and `/pii/deidentify` calls under load |
| `OPENMED_SERVICE_TRUSTED_HOSTS` | Host header allowlist — add your real domain before exposing publicly |
| `OPENMED_SERVICE_CORS_ORIGINS` | leave empty unless a browser needs to call this directly |
| `OPENMED_SERVICE_CIRCUIT_BREAKER_*` | opens circuit (503 + `Retry-After`) after repeated model failures instead of cascading |
| `OPENMED_API_KEY` | required — enforced in-process by `manage.py` (openmed itself has no built-in auth); the process refuses to start without it |
| `PORT` | listen port; Cloud Run overrides this per-instance, `manage.py`'s Dockerfile CMD reads whatever value is injected |

## Observability

- `GET /health`, `/livez`, `/readyz` for load balancer / orchestrator checks
- `GET /models/loaded` for warm-pool state (active requests, keep-alive remaining)
- `GET /metrics` (Prometheus, when `OPENMED_SERVICE_METRICS_ENABLED=true`) — no PHI-derived labels
- OpenTelemetry tracing via `OPENMED_SERVICE_OTLP_ENDPOINT` / `OPENMED_SERVICE_TRACING_ENABLED=true`
