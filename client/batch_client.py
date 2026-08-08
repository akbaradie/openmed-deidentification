"""Concurrent REST batch client for the openmed de-identification service.

Reads JSONL input (one {"id": ..., "text": ...} object per line), calls
POST /pii/deidentify for each record with bounded concurrency and retries,
and writes JSONL output with the redacted text alongside each id.

Use this from any environment that only has network access to the service
(no local openmed install required). For in-process batch processing on a
machine that has openmed installed, use client/batch_deidentify_local.py
instead -- it's faster and supports checkpoint/resume.

Example:
    python client/batch_client.py \\
        --base-url http://127.0.0.1:8080 \\
        --input examples/sample_input.jsonl \\
        --output results.jsonl \\
        --model OpenMed/privacy-filter-multilingual-v2 \\
        --method mask \\
        --concurrency 8
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import httpx


@dataclass
class BatchStats:
    total: int = 0
    succeeded: int = 0
    failed: int = 0
    failures: list[dict] = field(default_factory=list)


async def deidentify_one(
    client: httpx.AsyncClient,
    record: dict,
    *,
    model_name: str,
    method: str,
    lang: str,
    confidence_threshold: float,
    max_attempts: int,
    semaphore: asyncio.Semaphore,
) -> dict:
    payload = {
        "text": record["text"],
        "method": method,
        "lang": lang,
        "model_name": model_name,
        "confidence_threshold": confidence_threshold,
    }

    last_error: str | None = None
    async with semaphore:
        for attempt in range(1, max_attempts + 1):
            try:
                response = await client.post("/pii/deidentify", json=payload)
                if response.status_code == 429 or response.status_code >= 500:
                    last_error = f"HTTP {response.status_code}: {response.text[:300]}"
                    raise httpx.HTTPStatusError(last_error, request=response.request, response=response)
                response.raise_for_status()
                body = response.json()
                return {
                    "id": record.get("id"),
                    "success": True,
                    "deidentified_text": body["deidentified_text"],
                    "num_entities_redacted": body.get("num_entities_redacted"),
                }
            except (httpx.HTTPStatusError, httpx.TransportError) as exc:
                last_error = str(exc)
                if attempt < max_attempts:
                    await asyncio.sleep(min(2 ** attempt, 30))
                    continue
            except httpx.HTTPError as exc:
                # Client errors (4xx other than 429) are not retried.
                return {"id": record.get("id"), "success": False, "error": str(exc)}

    return {"id": record.get("id"), "success": False, "error": last_error or "unknown error"}


async def run_batch(args: argparse.Namespace) -> BatchStats:
    records = []
    with open(args.input, encoding="utf-8") as f:
        for line_no, line in enumerate(f, start=1):
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)
            record.setdefault("id", line_no)
            records.append(record)

    stats = BatchStats(total=len(records))
    semaphore = asyncio.Semaphore(args.concurrency)

    headers = {"X-API-Key": args.api_key} if args.api_key else {}

    async with httpx.AsyncClient(
        base_url=args.base_url, timeout=args.timeout, headers=headers
    ) as client:
        tasks = [
            deidentify_one(
                client,
                record,
                model_name=args.model,
                method=args.method,
                lang=args.lang,
                confidence_threshold=args.confidence_threshold,
                max_attempts=args.max_attempts,
                semaphore=semaphore,
            )
            for record in records
        ]

        with open(args.output, "w", encoding="utf-8") as out:
            for coro in asyncio.as_completed(tasks):
                result = await coro
                out.write(json.dumps(result, ensure_ascii=False) + "\n")
                if result["success"]:
                    stats.succeeded += 1
                else:
                    stats.failed += 1
                    stats.failures.append(result)
                done = stats.succeeded + stats.failed
                if done % max(1, args.progress_every) == 0 or done == stats.total:
                    print(f"[{done}/{stats.total}] ok={stats.succeeded} failed={stats.failed}", file=sys.stderr)

    return stats


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-url", required=True, help="e.g. http://127.0.0.1:8080")
    parser.add_argument("--input", required=True, type=Path, help="JSONL file with {id, text} per line")
    parser.add_argument("--output", required=True, type=Path, help="JSONL file to write results to")
    parser.add_argument("--model", default="OpenMed/privacy-filter-multilingual-v2")
    parser.add_argument("--method", default="mask", choices=["mask", "replace", "remove", "hash", "shift_dates"])
    parser.add_argument("--lang", default="en")
    parser.add_argument("--confidence-threshold", type=float, default=0.5)
    parser.add_argument("--concurrency", type=int, default=8)
    parser.add_argument("--max-attempts", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=310.0)
    parser.add_argument("--api-key", default=None, help="Sent as X-API-Key if the service sits behind an auth proxy")
    parser.add_argument("--progress-every", type=int, default=10)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    start = time.monotonic()
    stats = asyncio.run(run_batch(args))
    elapsed = time.monotonic() - start

    print(
        f"\nDone in {elapsed:.1f}s — total={stats.total} succeeded={stats.succeeded} failed={stats.failed}",
        file=sys.stderr,
    )
    if stats.failures:
        print(f"{len(stats.failures)} failures written to {args.output} (success=false entries)", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
