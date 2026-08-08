"""Shared helpers for the benchmark scripts: synthetic text generation,
CSV output, sweet-spot detection, and an optional throughput chart.

Chart colors come from the repo's validated dataviz palette (blue/orange,
CVD-safe adjacent pair) rather than matplotlib defaults.
"""

from __future__ import annotations

import csv
import json
from pathlib import Path

SERIES_BLUE = "#2a78d6"
SERIES_ORANGE = "#eb6834"
GRIDLINE = "#e1e0d9"
MUTED = "#898781"
PRIMARY_INK = "#0b0b0b"
SURFACE = "#fcfcfb"


def load_or_synthesize_texts(input_path: Path | None, num_samples: int) -> list[str]:
    """Load JSONL {"text": ...} records, or synthesize `num_samples` texts by
    cycling a small set of templates with a unique nonce appended.

    The nonce matters for REST benchmarks specifically: the service's request
    coalescing dedupes identical in-flight text, which would understate real
    concurrency cost if every synthetic item were byte-identical.
    """
    if input_path is not None:
        texts = []
        with open(input_path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                texts.append(json.loads(line)["text"])
        if num_samples:
            texts = (texts * (num_samples // len(texts) + 1))[:num_samples]
        return texts

    templates = [
        "Patient {name}, MRN {mrn}, called from {phone} about a refill.",
        "Paciente: {name}, correo {name_lower}@example.com, tel {phone}.",
        "Pasien {name}, NIK {mrn}, lahir pada tanggal terkait, dirawat di ruang {room}.",
        "{name} was admitted on 2026-0{d}-1{d} and discharged five days later.",
    ]
    texts = []
    for i in range(num_samples):
        template = templates[i % len(templates)]
        texts.append(
            template.format(
                name=f"Synthetic Patient {i}",
                name_lower=f"synthetic.patient{i}",
                mrn=f"{1000000 + i}",
                phone=f"555-{i % 10000:04d}",
                room=f"{3 + i % 9}0{1 + i % 8}",
                d=(i % 9) + 1,
            )
        )
    return texts


def write_csv(rows: list[dict], path: Path) -> None:
    if not rows:
        return
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def print_table(rows: list[dict]) -> None:
    if not rows:
        print("(no results)")
        return
    headers = list(rows[0].keys())
    widths = [max(len(h), *(len(f"{r[h]}") for r in rows)) for h in headers]
    fmt = "  ".join(f"{{:<{w}}}" for w in widths)
    print(fmt.format(*headers))
    print(fmt.format(*["-" * w for w in widths]))
    for r in rows:
        print(fmt.format(*[f"{r[h]}" for h in headers]))


def find_sweet_spot(rows: list[dict], x_key: str, throughput_key: str, tolerance: float = 0.05) -> dict:
    """Smallest x whose throughput is within `tolerance` of the observed max.

    Past this point extra batching/concurrency buys < tolerance more
    throughput -- diminishing returns, and larger batches cost more memory
    and worse per-item tail latency for no real gain.
    """
    best = max(rows, key=lambda r: r[throughput_key])
    threshold = best[throughput_key] * (1 - tolerance)
    candidates = [r for r in rows if r[throughput_key] >= threshold]
    return min(candidates, key=lambda r: r[x_key])


def plot_throughput(
    rows: list[dict],
    path: Path,
    *,
    x_key: str,
    throughput_key: str,
    xlabel: str,
    title: str,
    sweet_spot: dict | None = None,
) -> bool:
    """Best-effort PNG chart. Returns False (and skips) if matplotlib isn't installed."""
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("(matplotlib not installed -- skipping chart, CSV/table still written)")
        return False

    xs = [r[x_key] for r in rows]
    ys = [r[throughput_key] for r in rows]

    fig, ax = plt.subplots(figsize=(7, 4.5), dpi=150)
    fig.patch.set_facecolor(SURFACE)
    ax.set_facecolor(SURFACE)

    ax.plot(xs, ys, color=SERIES_BLUE, linewidth=2, marker="o", markersize=6, zorder=3)

    if sweet_spot is not None:
        ax.scatter(
            [sweet_spot[x_key]],
            [sweet_spot[throughput_key]],
            color=SERIES_ORANGE,
            s=90,
            zorder=4,
            label=f"sweet spot = {sweet_spot[x_key]}",
        )
        ax.legend(frameon=False, labelcolor=PRIMARY_INK)

    ax.set_xlabel(xlabel, color=MUTED)
    ax.set_ylabel("throughput (items/sec)", color=MUTED)
    ax.set_title(title, color=PRIMARY_INK, fontsize=12, loc="left")
    ax.set_xscale("log", base=2)
    ax.set_xticks(xs)
    ax.set_xticklabels([str(x) for x in xs])
    ax.grid(True, color=GRIDLINE, linewidth=1, zorder=0)
    for spine in ax.spines.values():
        spine.set_visible(False)
    ax.tick_params(colors=MUTED)

    fig.tight_layout()
    fig.savefig(path, facecolor=SURFACE)
    plt.close(fig)
    return True
