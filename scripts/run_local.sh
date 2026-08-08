#!/usr/bin/env bash
# Run the service directly on the host (no Docker). Useful for local dev
# and for environments without container support.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

export OPENMED_PROFILE="${OPENMED_PROFILE:-prod}"
export OPENMED_SERVICE_PRELOAD_MODELS="${OPENMED_SERVICE_PRELOAD_MODELS:-OpenMed/privacy-filter-multilingual-v2}"

if [ ! -d .venv ]; then
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate

pip install -q -r requirements.txt

HOST="${OPENMED_HOST:-127.0.0.1}"
PORT="${OPENMED_PORT:-8080}"

echo "Starting openmed service on ${HOST}:${PORT} (model=${OPENMED_SERVICE_PRELOAD_MODELS})"
exec uvicorn openmed.service.app:app --host "$HOST" --port "$PORT"
