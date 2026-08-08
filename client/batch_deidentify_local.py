"""In-process batch de-identification using openmed.BatchProcessor.

Runs on a machine/notebook that has `openmed[hf]` installed directly --
no HTTP round-trip, and supports crash-safe checkpoint/resume for large
corpora. Prefer client/batch_client.py instead if you only have network
access to a running service.

Input: JSONL with one {"id": ..., "text": ...} object per line.
Output: JSON file (openmed's BatchResult.to_dict() shape) plus a
        flat JSONL of {id, deidentified_text, num_entities_redacted}.

Example:
    python client/batch_deidentify_local.py \\
        --input examples/sample_input.jsonl \\
        --output results.json \\
        --flat-output results.jsonl \\
        --model OpenMed/privacy-filter-multilingual-v2 \\
        --method mask \\
        --checkpoint-interval 25 \\
        --resume
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from openmed import BatchProcessor, BatchProgress


def load_records(path: Path) -> tuple[list[str], list[str]]:
    ids: list[str] = []
    texts: list[str] = []
    with open(path, encoding="utf-8") as f:
        for line_no, line in enumerate(f, start=1):
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)
            ids.append(str(record.get("id", line_no)))
            texts.append(record["text"])
    return ids, texts


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path, help="Full BatchResult JSON")
    parser.add_argument("--flat-output", type=Path, default=None, help="Optional flat JSONL of id/redacted text")
    parser.add_argument("--checkpoint", type=Path, default=None, help="Defaults to <output>.checkpoint.json")
    parser.add_argument("--model", default="OpenMed/privacy-filter-multilingual-v2")
    parser.add_argument("--method", default="mask", choices=["mask", "replace", "remove", "hash", "shift_dates"])
    parser.add_argument("--lang", default="en")
    parser.add_argument("--confidence-threshold", type=float, default=0.5)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--checkpoint-interval", type=int, default=25)
    parser.add_argument("--resume", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    ids, texts = load_records(args.input)
    checkpoint_path = args.checkpoint or args.output.with_suffix(".checkpoint.json")

    processor = BatchProcessor(
        operation="deidentify",
        model_name=args.model,
        method=args.method,
        lang=args.lang,
        confidence_threshold=args.confidence_threshold,
        batch_size=args.batch_size,
        continue_on_error=True,
        checkpoint_interval=args.checkpoint_interval,
    )

    def on_progress(progress: BatchProgress) -> None:
        print(f"[{progress.completed}/{progress.total}] elapsed={progress.elapsed:.1f}s")

    result = processor.process_texts(
        texts,
        ids=ids,
        output_path=args.output,
        checkpoint_path=checkpoint_path,
        resume_from_checkpoint=args.resume,
        on_progress=on_progress,
    )

    print(result.summary())

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(result.to_dict(), f, indent=2)

    if args.flat_output:
        with open(args.flat_output, "w", encoding="utf-8") as f:
            for item in result.items:
                row = {"id": item.id, "success": item.success}
                if item.success:
                    row["deidentified_text"] = item.result.deidentified_text
                    row["num_entities_redacted"] = item.result.num_entities_redacted
                else:
                    row["error"] = item.error
                f.write(json.dumps(row, ensure_ascii=False) + "\n")

    if result.failed_items:
        print(f"{result.failed_items} item(s) failed — see {args.output}")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
