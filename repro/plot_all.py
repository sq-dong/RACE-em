#!/usr/bin/env python3
"""Plot figures from repro/results/*.csv; layout close to RACE ATC / SepHash papers."""
from __future__ import annotations

import argparse
import csv
from pathlib import Path

import matplotlib.pyplot as plt
import matplotlib as mpl

# Paper style: white bg, clear grid, classic markers
mpl.rcParams.update(
    {
        "font.size": 11,
        "axes.labelsize": 12,
        "axes.titlesize": 12,
        "legend.fontsize": 10,
        "xtick.labelsize": 10,
        "ytick.labelsize": 10,
        "axes.grid": True,
        "grid.alpha": 0.35,
        "figure.dpi": 140,
        "savefig.bbox": "tight",
        "font.family": "DejaVu Sans",
    }
)

RACE_STYLE = dict(color="#1f77b4", marker="o", linewidth=2.0, markersize=7, label="RACE")


def read_csv(path: Path) -> list[dict]:
    if not path.exists():
        return []
    with path.open() as f:
        return list(csv.DictReader(f))


def fnum(row: dict, key: str, default=None):
    v = row.get(key, "")
    if v is None or v == "":
        return default
    try:
        return float(v)
    except ValueError:
        return default


def save(fig, out: Path):
    out.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out.with_suffix(".pdf"))
    fig.savefig(out.with_suffix(".png"))
    plt.close(fig)
    print(f"wrote {out}.pdf / .png")


def plot_race_tput(rows: list[dict], out: Path):
    if not rows:
        return
    # paper order: insert, search, deletion, update
    order = [("insert", "(a) Insertion"), ("search", "(b) Search"), ("delete", "(c) Deletion"), ("update", "(d) Update")]
    fig, axes = plt.subplots(2, 2, figsize=(8.5, 6.5), sharex=True)
    axes = axes.ravel()
    for ax, (op, title) in zip(axes, order):
        pts = [r for r in rows if r.get("op") == op]
        pts = sorted(pts, key=lambda r: fnum(r, "num_cli", 0))
        xs = [fnum(r, "num_cli") for r in pts]
        ys = [fnum(r, "run_mops") for r in pts]
        if not xs:
            ax.set_visible(False)
            continue
        ax.plot(xs, ys, **RACE_STYLE)
        ax.set_xscale("log", base=2)
        ax.set_xticks(xs)
        ax.get_xaxis().set_major_formatter(mpl.ticker.ScalarFormatter())
        ax.set_title(title)
        ax.set_xlabel("The Number of Client Processes")
        ax.set_ylabel("Throughput (M reqs/s)")
        ax.legend()
    fig.suptitle("RACE concurrent throughput", y=1.02)
    fig.tight_layout()
    save(fig, out)


def plot_race_hybrid(rows: list[dict], out: Path):
    if not rows:
        return
    rows = sorted(rows, key=lambda r: fnum(r, "search_frac", 0))
    # paper x: Search/Insertion Ratio (%) — we use search% as 10..90
    xs = [int(round(fnum(r, "search_frac", 0) * 100)) for r in rows]
    ys = [fnum(r, "run_mops") for r in rows]
    labels = [f"{int(round(fnum(r,'search_frac')*100))}/{int(round(fnum(r,'insert_frac')*100))}" for r in rows]
    fig, ax = plt.subplots(figsize=(6.2, 4.2))
    ax.plot(xs, ys, **RACE_STYLE)
    ax.set_xticks(xs)
    ax.set_xticklabels(labels, rotation=0)
    ax.set_xlabel("Search/Insertion Ratio (%)")
    ax.set_ylabel("Throughput (M reqs/s)")
    ax.set_title("RACE YCSB hybrid")
    ax.legend()
    fig.tight_layout()
    save(fig, out)


def plot_race_latency(rows: list[dict], out: Path, x_axis: str = "entry_util"):
    """x_axis: 'entry_util' | 'load_num' (latter saved separately; does not overwrite util fig)."""
    if not rows:
        return
    order = [("insert", "(a) Insertion"), ("search", "(b) Search"), ("delete", "(c) Deletion"), ("update", "(d) Update")]
    fig, axes = plt.subplots(2, 2, figsize=(8.5, 6.5))
    axes = axes.ravel()
    use_load = x_axis == "load_num"
    for ax, (op, title) in zip(axes, order):
        pts = [r for r in rows if r.get("op") == op]
        if use_load:
            pts = sorted(pts, key=lambda r: fnum(r, "load_num", 0))
            xs = [fnum(r, "load_num") / 1e6 for r in pts]
            ax.set_xlabel("Loaded items (millions)")
        else:
            def xkey(r):
                eu = fnum(r, "entry_util")
                return eu if eu is not None else fnum(r, "load_num", 0)

            pts = sorted(pts, key=xkey)
            if pts and fnum(pts[0], "entry_util") is not None:
                xs = [fnum(r, "entry_util") for r in pts]
                ax.set_xlabel("Entry utilization (≈ load factor)")
            else:
                xs = [fnum(r, "load_num") / 1e6 for r in pts]
                ax.set_xlabel("Loaded items (millions)")
        ys = [fnum(r, "avg_lat_us") for r in pts]
        ax.plot(xs, ys, **RACE_STYLE)
        ax.set_title(title)
        ax.set_ylabel("Average Latency (us)")
        ax.legend()
    fig.suptitle(
        "RACE latency vs loaded items" if use_load else "RACE latency vs load",
        y=1.02,
    )
    fig.tight_layout()
    save(fig, out)


def plot_race_ycsb(rows: list[dict], out: Path):
    if not rows:
        return
    order = ["A", "B", "C", "D"]
    xs = []
    ys = []
    for w in order:
        pts = [r for r in rows if r.get("workload") == w]
        if not pts:
            continue
        xs.append(w)
        ys.append(fnum(pts[-1], "run_mops"))
    fig, ax = plt.subplots(figsize=(5.5, 4.0))
    ax.bar(xs, ys, color="#1f77b4", width=0.55, label="RACE")
    ax.set_xlabel("YCSB Workload")
    ax.set_ylabel("Throughput (M ops/s)")
    ax.set_title("RACE on YCSB A–D")
    ax.legend()
    fig.tight_layout()
    save(fig, out)


def plot_race_varlen(rows: list[dict], out: Path):
    """Variable-length KV: four curves Insertion / Search / Deletion / Update."""
    if not rows:
        return
    # paper legend order
    styles = [
        ("insert", "Insertion", dict(color="#1f77b4", marker="o", linewidth=2.0, markersize=7)),
        ("search", "Search", dict(color="#ff7f0e", marker="s", linewidth=2.0, markersize=7)),
        ("delete", "Deletion", dict(color="#2ca02c", marker="^", linewidth=2.0, markersize=7)),
        ("update", "Update", dict(color="#d62728", marker="D", linewidth=2.0, markersize=7)),
    ]
    fig, ax = plt.subplots(figsize=(5.5, 4.0))
    any_pts = False
    for op, label, style in styles:
        pts = sorted([r for r in rows if r.get("op") == op], key=lambda r: fnum(r, "value_len", 0))
        xs = [fnum(r, "value_len") for r in pts]
        ys = [fnum(r, "avg_lat_us") for r in pts]
        if not xs:
            continue
        any_pts = True
        ax.plot(xs, ys, label=label, **style)
    if not any_pts:
        plt.close(fig)
        return
    ax.set_xscale("log", base=2)
    ax.set_xlabel("Key-value Block Size (Bytes)")
    ax.set_ylabel("Average Latency (us)")
    ax.legend()
    ax.set_title("RACE variable KV sizes")
    fig.tight_layout()
    save(fig, out)


def plot_sephash_insert(rows: list[dict], out: Path):
    if not rows:
        return
    rows = sorted(rows, key=lambda r: fnum(r, "num_cli", 0))
    xs = [fnum(r, "num_cli") for r in rows]
    ys = [fnum(r, "load_mops") for r in rows]
    fig, ax = plt.subplots(figsize=(5.8, 4.0))
    ax.plot(xs, ys, **RACE_STYLE)
    ax.set_xscale("log", base=2)
    ax.set_xticks(xs)
    ax.get_xaxis().set_major_formatter(mpl.ticker.ScalarFormatter())
    ax.set_xlabel("Number of Threads")
    ax.set_ylabel("Throughput (Mops)")
    ax.set_title("Insert throughput (RACE only)")
    ax.legend()
    fig.tight_layout()
    save(fig, out)


def plot_sephash_hybrid(rows: list[dict], out: Path):
    if not rows:
        return
    # keep CSV order
    xs = list(range(len(rows)))
    labels = [r.get("insert_search_label", "") for r in rows]
    ys = [fnum(r, "run_mops") for r in rows]
    fig, ax = plt.subplots(figsize=(6.2, 4.0))
    ax.plot(xs, ys, **RACE_STYLE)
    ax.set_xticks(xs)
    ax.set_xticklabels(labels)
    ax.set_xlabel("Insert/Search Ratio")
    ax.set_ylabel("Throughput (Mops)")
    ax.set_title("Hybrid workloads (RACE only)")
    ax.legend()
    fig.tight_layout()
    save(fig, out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", type=Path, default=Path(__file__).resolve().parent / "results")
    args = ap.parse_args()
    res = args.results
    figdir = res / "figures"

    plot_race_tput(read_csv(res / "race_tput.csv"), figdir / "fig_race_tput")
    plot_race_hybrid(read_csv(res / "race_hybrid.csv"), figdir / "fig_race_hybrid")
    lat_rows = read_csv(res / "race_latency.csv")
    plot_race_latency(lat_rows, figdir / "fig_race_latency")  # x-axis entry_util (kept)
    plot_race_latency(lat_rows, figdir / "fig_race_latency_by_load", x_axis="load_num")
    plot_race_ycsb(read_csv(res / "race_ycsb.csv"), figdir / "fig_race_ycsb")
    plot_race_varlen(read_csv(res / "race_varlen.csv"), figdir / "fig_race_varlen")
    plot_sephash_insert(read_csv(res / "sephash_insert.csv"), figdir / "fig_sephash_insert")
    plot_sephash_hybrid(read_csv(res / "sephash_hybrid.csv"), figdir / "fig_sephash_hybrid")

    # summary index
    index = figdir / "INDEX.md"
    lines = ["# Generated figures\n", f"Results dir: `{res}`\n"]
    for p in sorted(figdir.glob("*.png")):
        lines.append(f"- `{p.name}`\n")
    index.write_text("".join(lines))
    print(f"index -> {index}")


if __name__ == "__main__":
    main()
