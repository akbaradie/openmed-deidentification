#!/usr/bin/env bash
# One-shot bring-up for Google Colab (or any notebook environment):
# installs deps, starts the openmed service in the background, waits for
# readiness, and opens an ngrok tunnel so it's reachable from outside the VM.
#
# Usage inside a Colab cell:
#   !git clone <this-repo> openmed-deidentification
#   %env NGROK_AUTH_TOKEN=...
#   !bash openmed-deidentification/scripts/run_colab.sh
#
# Env vars:
#   NGROK_AUTH_TOKEN   required, from https://dashboard.ngrok.com
#   NGROK_HOSTNAME      optional, a reserved ngrok domain; random URL if unset
#   OPENMED_SERVICE_PRELOAD_MODELS  defaults to the privacy-filter model below
set -euo pipefail

cd "$(dirname "$0")/.."

: "${NGROK_AUTH_TOKEN:?Set NGROK_AUTH_TOKEN before running (dashboard.ngrok.com)}"

export OPENMED_PROFILE="${OPENMED_PROFILE:-prod}"
export OPENMED_SERVICE_PRELOAD_MODELS="${OPENMED_SERVICE_PRELOAD_MODELS:-OpenMed/privacy-filter-multilingual-v2}"
export OPENMED_SERVICE_BATCHING_ENABLED="${OPENMED_SERVICE_BATCHING_ENABLED:-true}"
export OPENMED_SERVICE_MAX_RESIDENT_MODELS="${OPENMED_SERVICE_MAX_RESIDENT_MODELS:-1}"
HOST=127.0.0.1
PORT="${OPENMED_PORT:-8000}"

# Host header allowlist must be set before the server starts. With a
# reserved ngrok domain (NGROK_HOSTNAME) we can allowlist it precisely.
# Without one, ngrok assigns a random hostname we can't know in advance,
# so trusted-host checking is relaxed here for the demo/Colab case only
# -- do not carry that over to a real production deployment.
if [ -n "${NGROK_HOSTNAME:-}" ]; then
  export OPENMED_SERVICE_TRUSTED_HOSTS="localhost,127.0.0.1,${NGROK_HOSTNAME}"
else
  echo ">> WARNING: NGROK_HOSTNAME not set; relaxing trusted-host checks for this random-domain tunnel (demo only)." >&2
  export OPENMED_SERVICE_TRUSTED_HOSTS="*"
fi

echo ">> Installing dependencies (openmed[hf,service], pyngrok)..."
pip install -q "openmed[hf,service]" pyngrok

echo ">> Starting openmed service on ${HOST}:${PORT} (model=${OPENMED_SERVICE_PRELOAD_MODELS})..."
nohup uvicorn openmed.service.app:app --host "$HOST" --port "$PORT" > openmed_service.log 2>&1 &
SERVICE_PID=$!
echo "$SERVICE_PID" > openmed_service.pid

echo ">> Waiting for /readyz..."
for _ in $(seq 1 120); do
  if curl -fsS "http://${HOST}:${PORT}/readyz" >/dev/null 2>&1; then
    echo ">> Service is ready."
    break
  fi
  if ! kill -0 "$SERVICE_PID" 2>/dev/null; then
    echo "!! Service process died. Last log lines:" >&2
    tail -n 50 openmed_service.log >&2
    exit 1
  fi
  sleep 2
done

if ! curl -fsS "http://${HOST}:${PORT}/readyz" >/dev/null 2>&1; then
  echo "!! Service did not become ready in time. Last log lines:" >&2
  tail -n 50 openmed_service.log >&2
  exit 1
fi

python3 - "$PORT" "${NGROK_HOSTNAME:-}" <<'PYEOF'
import sys
from pyngrok import ngrok
import os

port = int(sys.argv[1])
hostname = sys.argv[2] or None

ngrok.set_auth_token(os.environ["NGROK_AUTH_TOKEN"])
kwargs = {"hostname": hostname} if hostname else {}
tunnel = ngrok.connect(addr=port, proto="http", **kwargs)
print(f"\n>> Public URL: {tunnel.public_url}\n")
with open("openmed_tunnel_url.txt", "w") as f:
    f.write(tunnel.public_url)
PYEOF

echo ">> Tunnel URL saved to openmed_tunnel_url.txt"
echo ">> Service logs: tail -f openmed_service.log"
echo ">> Stop with: kill \$(cat openmed_service.pid)"
echo ">> Smoke test: bash scripts/smoke_test.sh http://${HOST}:${PORT}"
