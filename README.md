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
docker/Dockerfile           image: model baked in at build time, uv + CPU-only torch, non-root, single worker, $PORT-aware, healthcheck
docker/Caddyfile             VM-only: TLS termination + proxy (no auth logic -- app owns that)
docker-compose.yml            openmed + Caddy, named volume for the HF cache (VM target)
scripts/setup_gcp.sh           one-time: Artifact Registry, secrets, IAM, WIF trust for CI
scripts/deploy_cloud_run.sh   build (model baked in, cached) + deploy to Cloud Run
cloudbuild.yaml                buildx build w/ registry layer cache, BuildKit secret for HF_TOKEN
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
notebooks/explore_endpoint.ipynb  interactive exploration of a deployed endpoint (health, deidentify, extract, small batch)
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
export HF_TOKEN=...                    # free, read-scoped token from huggingface.co/settings/tokens -- see note below
export GITHUB_REPO=you/openmed-deidentification   # for the WIF trust binding, see CI/CD below
bash scripts/setup_gcp.sh

# every deploy (redeploys, or what CI calls):
export PROJECT_ID=your-gcp-project
bash scripts/deploy_cloud_run.sh
```

**The model is baked into the image, not mounted from GCS.**
`docker/Dockerfile` downloads `OpenMed/privacy-filter-multilingual-v2`
(~2.8GB) during `docker build` via `huggingface_hub.snapshot_download`,
straight into `HF_HOME`. At runtime there's no FUSE mount, no network read
— just a local file already sitting in the image, and
`HF_HUB_OFFLINE=1` (set by `deploy_cloud_run.sh`) stops `huggingface_hub`
from even pinging the Hub API to check freshness. Confirmed in practice:
without it, cold start logged an unauthenticated Hub API call anyway
despite the model already being local — easy to miss, since it doesn't
fail until that shared-IP rate limit trips. Worth being precise about the
actual payoff here: this change eliminates the GCS mount and that
runtime Hub API call (a real reliability/rate-limit win), but **measured
cold-start time was unchanged** by this step alone — see the table further
down for what actually moved that number.

The obvious tradeoff: every build downloads that ~2.8GB too, not just the
first cold start. `cloudbuild.yaml` addresses that with `buildx` +
registry-backed layer caching (`--cache-from`/`--cache-to` against a
`:buildcache` tag) — a build that doesn't touch `requirements.txt` or the
download step reuses that layer entirely. Measured effect: a deploy that
only changed an env var went from **8m39s → 21s**. A build cache miss
(e.g. bumping the model version) still pays the full download.

What `setup_gcp.sh` does once: creates the Artifact Registry repo (also
holds the `:buildcache` tag), stores `OPENMED_API_KEY` (runtime) and
`HF_TOKEN` (build-time only now — pulled into the build via a BuildKit
secret, per `RUN --mount=type=secret` in the Dockerfile, so it never lands
in an image layer) in Secret Manager, grants whichever service account
Cloud Build actually executes as access to both (this varies by
project — granted to both plausible candidates rather than guessing), and
sets up Workload Identity Federation so GitHub Actions can deploy without
a stored key (see CI/CD below).

What `deploy_cloud_run.sh` does every time: builds via `cloudbuild.yaml`
(buildx, not a plain `docker build` — needed for the registry cache and
the BuildKit secret mount), pushes to Artifact Registry, and deploys with
`--cpu-throttling` (Cloud Run's default — CPU only allocated while
actively processing a request, cheaper than always-allocated; see the
comment block in the script for why this is safe with a single preloaded
model and `--max-instances 1`), `--cpu-boost` (extra CPU during the
startup phase specifically — part of what got cold start from 41.7s to
31.6s, see the latency section below), `--concurrency 256`
`--max-instances 1` (queues concurrent requests onto one instance rather
than scaling out — see the throughput caveat below),
`--allow-unauthenticated` (Cloud Run's own IAM gate is off; the app-level
`X-API-Key` check is what protects it, same as the VM), and
`--clear-volumes --clear-volume-mounts` (belt-and-suspenders now that
nothing's mounted — `gcloud run deploy` otherwise carries forward
unspecified resource/volume settings from the live revision, the same
mechanism that required an explicit `--gpu: "0"` after a GPU was once
attached via the console; see the comment block in the script). It also
sets `OPENMED_SKIP_MODEL_VERIFY=1` — see the comment block at the top of
the script for why: `openmed 2.0.0`'s bundled integrity check hashes the
HF repo's *commit metadata*, not the model weights, so it false-positives
on any trivial commit (confirmed for this exact model: the weights haven't
changed since upload, only a README got edited after the package's
manifest was frozen). Revisit this once openmed ships a fix.

Cold starts still happen whenever an instance scales up from zero. If you
need zero cold starts entirely, set `MIN_INSTANCES=1` before running
`deploy_cloud_run.sh` (an always-on instance costs more but skips
scale-from-zero altogether) — deliberately left at the default `0` here to
stay cost-conscious, in the same spirit as `--cpu-throttling` below.

**What actually moved the cold-start number, measured, not assumed:**

| Change | Instance start → app ready |
|---|---|
| GCS-mounted model | 41.71s |
| Baked into image (CUDA `torch`, no other changes) | 41.71s — **no improvement** |
| Baked in + CPU-only `torch` (`uv`, `UV_TORCH_BACKEND=cpu`) + `--cpu-boost` | **31.62s** |

The first row-to-row comparison is important: baking the model in and
removing the GCS FUSE mount made *no measurable difference* — the mount
itself only took ~0.5s, and the ~25s dominant cost in every case is
Python/`torch`/`transformers` import time, unrelated to where the model
file lives. What actually helped was the CPU-only `torch` wheel (this
deployment has no GPU, so the default CUDA-enabled wheel was spending
import time loading NVIDIA shared libraries it would never use) plus
Cloud Run's `--cpu-boost` (extra CPU specifically during the startup
phase). ~24% faster, real and reproducible — but don't assume the next
plausible-sounding optimization helps without measuring it the same way
(`gcloud logging read` on `resource.labels.revision_name`, diff
"Starting new instance" against "Application startup complete").

**Inference latency is real and CPU-bound, separately from cold start.**
A single short-text `/pii/deidentify` request took ~44 seconds end-to-end
on `--cpu 2 --memory 4Gi` — this is a 1.4B-parameter MoE model running on
CPU only, not a hung request. Practical implications:
- Client timeouts need real headroom — 60s (this repo's original default)
  isn't enough; `scripts/smoke_test.sh` now uses 180s.
- `--concurrency 256` with `--max-instances 1` (this repo's current
  defaults) raises how many requests Cloud Run will *queue* onto the one
  instance, not how many run truly in parallel — 2 vCPUs doing ~40s of
  CPU-bound work per request means real throughput is closer to one
  request at a time, and anything beyond that queues with worse tail
  latency. Not yet load-tested against these exact settings; confirm with
  `client/benchmark_rest.py --concurrency-levels ...` against the deployed
  URL before assuming it holds up.
- If real traffic needs better latency/throughput than this, look at
  Cloud Run's GPU support (`--gpu`) or a smaller/quantized model before
  scaling horizontally with more CPU-only instances.

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
