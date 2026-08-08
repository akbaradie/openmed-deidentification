"""Benchmark: sequential (concurrency=1) vs concurrent requests against a
running openmed service, sweeping concurrency to find the sweet spot.

Concurrency=1 is the true non-batched baseline here: the server's dynamic
request batching (OPENMED_SERVICE_BATCHING_ENABLED) can only coalesce
requests that are actually in flight together, so it never engages when
requests are sent one at a time. Raising concurrency is what exercises it.

Run this against a service already warmed up (model preloaded, see
.env.example OPENMED_SERVICE_PRELOAD_MODELS) so you're measuring steady
-state throughput, not cold-start.

Example:
    python client/benchmark_rest.py \\
        --base-url http://127.0.0.1:8080 \\
        --num-samples 200 \\
        --concurrency-levels 1,2,4,8,16,32 \\
        --model OpenMed/privacy-filter-multilingual-v2 \\
        --out-prefix bench_rest
"""

from __future__ import annotations

import argparse
import asyncio
import time
from pathlib import Path

import httpx
from benchmark_common import (
    find_sweet_spot,
    load_or_synthesize_texts,
    plot_throughput,
    print_table,
    write_csv,
)


async def deidentify_one(client: httpx.AsyncClient, text: str, *, model: str, method: str, lang: str, confidence_threshold: float) -> None:
    response = await client.post(
        "/pii/deidentify",
        json={
            "text": text,
            "method": method,
            "lang": lang,
            "model_name": model,
            "confidence_threshold": confidence_threshold,
        },
    )
    response.raise_for_status()


async def run_concurrency_level(
    client: httpx.AsyncClient,
    texts: list[str],
    concurrency: int,
    **kwargs,
) -> dict:
    semaphore = asyncio.Semaphore(concurrency)

    async def bound(text: str) -> None:
        async with semaphore:
            await deidentify_one(client, text, **kwargs)

    start = time.perf_counter()
    await asyncio.gather(*(bound(t) for t in texts))
    elapsed = time.perf_counter() - start
    return {
        "concurrency": concurrency,
        "total_items": len(texts),
        "elapsed_s": round(elapsed, 3),
        "throughput_items_per_s": round(len(texts) / elapsed, 2),
    }


async def run_all(args: argparse.Namespace) -> list[dict]:
    texts = load_or_synthesize_texts(args.input, args.num_samples)
    levels = [int(c) for c in args.concurrency_levels.split(",")]
    headers = {"X-API-Key": args.api_key} if args.api_key else {}
    kwargs = dict(model=args.model, method=args.method, lang=args.lang, confidence_threshold=args.confidence_threshold)

    rows: list[dict] = []
    async with httpx.AsyncClient(base_url=args.base_url, timeout=args.timeout, headers=headers) as client:
        print(">> Warming up (one request)...")
        await deidentify_one(client, texts[0], **kwargs)

        for level in levels:
            label = "sequential (no batching)" if level == 1 else f"concurrency={level}"
            print(f">> {label}: {len(texts)} items...")
            row = await run_concurrency_level(client, texts, level, **kwargs)
            row["mode"] = label
            rows.append(row)
            print(f"   {row['throughput_items_per_s']} items/sec")
    return rows


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--input", type=Path, default=None, help="JSONL {text: ...}; omit to synthesize")
    parser.add_argument("--num-samples", type=int, default=200)
    parser.add_argument("--concurrency-levels", default="1,2,4,8,16,32")
    parser.add_argument("--model", default="OpenMed/privacy-filter-multilingual-v2")
    parser.add_argument("--method", default="mask", choices=["mask", "replace", "remove", "hash", "shift_dates"])
    parser.add_argument("--lang", default="en")
    parser.add_argument("--confidence-threshold", type=float, default=0.5)
    parser.add_argument("--timeout", type=float, default=310.0)
    parser.add_argument("--api-key", default=None)
    parser.add_argument("--out-prefix", default="bench_rest")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    rows = asyncio.run(run_all(args))

    print()
    print_table(rows)

    csv_path = Path(f"{args.out_prefix}.csv")
    write_csv(rows, csv_path)
    print(f"\nWrote {csv_path}")

    sweet_spot = find_sweet_spot(rows, x_key="concurrency", throughput_key="throughput_items_per_s")
    baseline = next(r for r in rows if r["concurrency"] == 1)
    speedup = sweet_spot["throughput_items_per_s"] / baseline["throughput_items_per_s"]
    print(
        f"\nSweet spot: concurrency={sweet_spot['concurrency']} "
        f"({sweet_spot['throughput_items_per_s']} items/sec, "
        f"{speedup:.2f}x the sequential baseline of {baseline['throughput_items_per_s']} items/sec)"
    )

    png_path = Path(f"{args.out_prefix}.png")
    plotted = plot_throughput(
        rows,
        png_path,
        x_key="concurrency",
        throughput_key="throughput_items_per_s",
        xlabel="client concurrency",
        title=f"REST throughput vs concurrency ({args.model})",
        sweet_spot=sweet_spot,
    )
    if plotted:
        print(f"Wrote {png_path}")


if __name__ == "__main__":
    main()
