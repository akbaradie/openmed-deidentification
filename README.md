# openmed-deidentification

Production deployment of the [OpenMed REST service](https://openmed.life/docs/rest-service/)
pinned to **`OpenMed/privacy-filter-multilingual-v2`**, with batch tooling for
processing large numbers of documents.

The service itself ships inside the `openmed` package
(`openmed.service.app:app`, FastAPI/Uvicorn). This repo wraps it with:

- a hardened Docker image + Compose stack (model warm pool, Caddy reverse
  proxy enforcing an API key, healthchecks, persistent HF cache volume)
- an `.env` covering the production knobs (batching, resilience, limits)
- a one-shot Colab bring-up script (server + ngrok tunnel)
- two batch clients: a REST client for remote use, and an in-process
  `BatchProcessor`-based script with checkpoint/resume for local/Colab use

## Layout

```
docker/Dockerfile        production image (non-root, single worker, healthcheck)
docker/Caddyfile         reverse proxy: API key enforcement + optional TLS
docker-compose.yml        openmed + proxy, with a named volume for the HF cache
.env.example              copy to .env and fill in
scripts/run_local.sh       run directly on the host (no Docker)
scripts/run_colab.sh       install + start + ngrok tunnel, for Colab
scripts/smoke_test.sh      health check + one deidentify call
client/batch_client.py         REST batch client (async, retries, concurrency)
client/batch_deidentify_local.py  in-process batch via openmed.BatchProcessor
client/benchmark_local.py       naive loop vs BatchProcessor, sweeps batch_size
client/benchmark_rest.py        sequential vs concurrent REST calls, sweeps concurrency
client/benchmark_common.py      shared synth-data / CSV / chart helpers
examples/sample_input.jsonl     sample batch input
```

## Why a single worker

The model warm pool lives in-process. Running multiple Uvicorn workers would
each load their own copy of `OpenMed/privacy-filter-multilingual-v2`,
multiplying memory use for no benefit. Scale horizontally — run more
containers behind a load balancer — instead of `--workers N`.

## Quickstart: Docker Compose (recommended for production)

```bash
cp .env.example .env
# edit .env: set OPENMED_API_KEY, HF_TOKEN if the model is gated,
# and OPENMED_SERVICE_TRUSTED_HOSTS / OPENMED_SERVICE_CORS_ORIGINS for your domain

docker compose up -d --build
docker compose ps          # wait for openmed to report (healthy)

bash scripts/smoke_test.sh http://127.0.0.1:8080
```

Requests must include `X-API-Key: <OPENMED_API_KEY>` — Caddy rejects
anything else with 401 before it reaches the service. Put a real domain in
`docker/Caddyfile` to get automatic TLS from Let's Encrypt.

## Quickstart: local (no Docker)

```bash
cp .env.example .env
bash scripts/run_local.sh
# in another shell:
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

with OpenMedClient("http://127.0.0.1:8080", timeout=310.0) as client:
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
| `OPENMED_API_KEY` | consumed by `docker/Caddyfile`, not by openmed itself — openmed has no built-in auth |

## Observability

- `GET /health`, `/livez`, `/readyz` for load balancer / orchestrator checks
- `GET /models/loaded` for warm-pool state (active requests, keep-alive remaining)
- `GET /metrics` (Prometheus, when `OPENMED_SERVICE_METRICS_ENABLED=true`) — no PHI-derived labels
- OpenTelemetry tracing via `OPENMED_SERVICE_OTLP_ENDPOINT` / `OPENMED_SERVICE_TRACING_ENABLED=true`
