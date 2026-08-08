#!/usr/bin/env bash
# Quick end-to-end check against a running service. Confirms health,
# the target model, and one de-identification round-trip.
#
# Usage: bash scripts/smoke_test.sh [base_url]
# OPENMED_API_KEY must be set -- manage.py rejects everything but
# /health, /livez, /readyz without a matching X-API-Key header.
set -euo pipefail

BASE_URL="${1:-http://127.0.0.1:8080}"
MODEL="${OPENMED_MODEL:-OpenMed/privacy-filter-multilingual-v2}"
: "${OPENMED_API_KEY:?Set OPENMED_API_KEY (same value the service was started with)}"

echo "== health (unauthenticated) =="
curl -fsS --max-time 10 "$BASE_URL/health" | tee /dev/stderr
echo

echo "== readyz (unauthenticated) =="
curl -fsS --max-time 10 "$BASE_URL/readyz" | tee /dev/stderr
echo

echo "== deidentify (model=$MODEL) =="
# If this is the first inference call since a cold start, budget 40-70s --
# that's torch's one-time CPU init (thread pool, kernel selection), not
# per-request cost. Steady-state (instance already warm) is single-digit
# seconds. Not a hung connection either way; see the latency note in
# README.md (corrected there after an early measurement mistook the
# first-call cost for steady state).
curl -fsS --max-time 180 -X POST "$BASE_URL/pii/deidentify" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $OPENMED_API_KEY" \
  -d "{\"text\": \"Patient Jordan Ramirez, MRN 4482910, called from 555-0147.\", \"method\": \"mask\", \"lang\": \"en\", \"model_name\": \"$MODEL\"}"
echo

echo "OK"
