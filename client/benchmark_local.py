"""Benchmark: naive one-at-a-time deidentify() vs openmed.BatchProcessor
across a sweep of batch sizes, run in-process (openmed installed locally).

Answers two questions:
  1. Does batching beat calling deidentify() in a loop, and by how much?
  2. Which batch_size is the sweet spot -- past what point does a bigger
     batch stop paying for itself?

Example:
    python client/benchmark_local.py \\
        --num-samples 200 \\
        --batch-sizes 1,2,4,8,16,32,64 \\
        --model OpenMed/privacy-filter-multilingual-v2 \\
        --out-prefix bench_local
"""

from __future__ import annotations

import argparse
import time
from pathlib import Path

from benchmark_common import (
    find_sweet_spot,
    load_or_synthesize_texts,
    plot_throughput,
    print_table,
    write_csv,
)

from openmed import BatchProcessor, deidentify


def run_naive_sequential(texts: list[str], *, model: str, method: str, lang: str, confidence_threshold: float) -> dict:
    start = time.perf_counter()
    for text in texts:
        deidentify(
            text,
            method=method,
            lang=lang,
            model_name=model,
            confidence_threshold=confidence_threshold,
        )
    elapsed = time.perf_counter() - start
    return {
        "mode": "sequential (no batching)",
        "batch_size": 1,
        "total_items": len(texts),
        "elapsed_s": round(elapsed, 3),
        "throughput_items_per_s": round(len(texts) / elapsed, 2),
    }


def run_batched(texts: list[str], batch_size: int, *, model: str, method: str, lang: str, confidence_threshold: float) -> dict:
    processor = BatchProcessor(
        operation="deidentify",
        model_name=model,
        method=method,
        lang=lang,
        confidence_threshold=confidence_threshold,
        batch_size=batch_size,
        continue_on_error=False,
    )
    start = time.perf_counter()
    result = processor.process_texts(texts)
    elapsed = time.perf_counter() - start
    return {
        "mode": "BatchProcessor",
        "batch_size": batch_size,
        "total_items": result.total_items,
        "elapsed_s": round(elapsed, 3),
        "throughput_items_per_s": round(result.total_items / elapsed, 2),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", type=Path, default=None, help="JSONL {text: ...}; omit to synthesize")
    parser.add_argument("--num-samples", type=int, default=200)
    parser.add_argument("--batch-sizes", default="1,2,4,8,16,32,64")
    parser.add_argument("--model", default="OpenMed/privacy-filter-multilingual-v2")
    parser.add_argument("--method", default="mask", choices=["mask", "replace", "remove", "hash", "shift_dates"])
    parser.add_argument("--lang", default="en")
    parser.add_argument("--confidence-threshold", type=float, default=0.5)
    parser.add_argument("--repeats", type=int, default=1, help="Repeat each measurement and keep the best (warm) run")
    parser.add_argument("--skip-baseline", action="store_true", help="Skip the naive sequential baseline")
    parser.add_argument("--out-prefix", default="bench_local")
    return parser.parse_args()


def best_of(fn, repeats: int) -> dict:
    runs = [fn() for _ in range(repeats)]
    return min(runs, key=lambda r: r["elapsed_s"])


def main() -> None:
    args = parse_args()
    texts = load_or_synthesize_texts(args.input, args.num_samples)
    batch_sizes = [int(b) for b in args.batch_sizes.split(",")]
    common_kwargs = dict(model=args.model, method=args.method, lang=args.lang, confidence_threshold=args.confidence_threshold)

    print(f">> Warming up model ({args.model})...")
    deidentify(texts[0], method=args.method, lang=args.lang, model_name=args.model, confidence_threshold=args.confidence_threshold)

    rows: list[dict] = []

    if not args.skip_baseline:
        print(f">> Baseline: {len(texts)} items, one deidentify() call at a time...")
        baseline = best_of(lambda: run_naive_sequential(texts, **common_kwargs), args.repeats)
        rows.append(baseline)
        print(f"   {baseline['throughput_items_per_s']} items/sec")

    for batch_size in batch_sizes:
        print(f">> BatchProcessor batch_size={batch_size} ({len(texts)} items)...")
        row = best_of(lambda: run_batched(texts, batch_size, **common_kwargs), args.repeats)
        rows.append(row)
        print(f"   {row['throughput_items_per_s']} items/sec")

    print()
    print_table(rows)

    csv_path = Path(f"{args.out_prefix}.csv")
    write_csv(rows, csv_path)
    print(f"\nWrote {csv_path}")

    batched_rows = [r for r in rows if r["mode"] == "BatchProcessor"]
    sweet_spot = find_sweet_spot(batched_rows, x_key="batch_size", throughput_key="throughput_items_per_s")
    baseline_row = next((r for r in rows if r["mode"] != "BatchProcessor"), None)

    if baseline_row:
        speedup = sweet_spot["throughput_items_per_s"] / baseline_row["throughput_items_per_s"]
        print(
            f"\nSweet spot: batch_size={sweet_spot['batch_size']} "
            f"({sweet_spot['throughput_items_per_s']} items/sec, "
            f"{speedup:.2f}x the non-batched baseline of {baseline_row['throughput_items_per_s']} items/sec)"
        )
    else:
        print(f"\nSweet spot: batch_size={sweet_spot['batch_size']} ({sweet_spot['throughput_items_per_s']} items/sec)")

    png_path = Path(f"{args.out_prefix}.png")
    plotted = plot_throughput(
        batched_rows,
        png_path,
        x_key="batch_size",
        throughput_key="throughput_items_per_s",
        xlabel="batch_size",
        title=f"BatchProcessor throughput vs batch_size ({args.model})",
        sweet_spot=sweet_spot,
    )
    if plotted:
        print(f"Wrote {png_path}")


if __name__ == "__main__":
    main()
