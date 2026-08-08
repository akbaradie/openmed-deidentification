#!/usr/bin/env bash
# Quick end-to-end check against a running service. Confirms health,
# the target model, and one de-identification round-trip.
set -euo pipefail

BASE_URL="${1:-http://127.0.0.1:8080}"
MODEL="${OPENMED_MODEL:-OpenMed/privacy-filter-multilingual-v2}"

echo "== health =="
curl -fsS --max-time 10 "$BASE_URL/health" | tee /dev/stderr
echo

echo "== readyz =="
curl -fsS --max-time 10 "$BASE_URL/readyz" | tee /dev/stderr
echo

echo "== deidentify (model=$MODEL) =="
curl -fsS --max-time 60 -X POST "$BASE_URL/pii/deidentify" \
  -H "Content-Type: application/json" \
  -d "{\"text\": \"Patient Jordan Ramirez, MRN 4482910, called from 555-0147.\", \"method\": \"mask\", \"lang\": \"en\", \"model_name\": \"$MODEL\"}"
echo

echo "OK"
