#!/usr/bin/env python3
"""Summarize benchmark CSVs into per-cell mean/std tables (paper §Evaluation).

Usage:
    python3 analyze.py results/matrix.csv
    python3 analyze.py results/integrity.csv
Figures are generated separately during paper preparation.
"""
import sys

import pandas as pd


def summarize_matrix(df: pd.DataFrame) -> None:
    df = df.dropna(subset=["total_s"])
    q1 = lambda s: s.quantile(0.25)  # noqa: E731
    q3 = lambda s: s.quantile(0.75)  # noqa: E731
    cells = (
        df.groupby(["scheme", "size_gb", "mode"])
        .agg(
            n=("total_s", "size"),
            total_median=("total_s", "median"),
            total_q1=("total_s", q1),
            total_q3=("total_s", q3),
            init_median=("scheduled_to_initialized_s", "median"),
            ready_median=("initialized_to_ready_s", "median"),
            predict_median=("ready_to_first200_s", "median"),
            disk_median=("disk_delta_bytes", "median"),
        )
        .round(2)
    )
    print(cells.to_string())
    out = sys.argv[1].replace(".csv", "-summary.csv")
    cells.to_csv(out)
    print(f"\nwritten: {out}")
    failures = df[df["notes"].notna() & (df["notes"] != "")]
    if len(failures):
        print(f"\nWARNING: {len(failures)} runs had notes/failures — inspect before using results")


def summarize_integrity(df: pd.DataFrame) -> None:
    cells = (
        df.groupby(["size_gb", "variant"])
        .agg(
            n=("total_s", "size"),
            total_mean=("total_s", "mean"),
            total_std=("total_s", "std"),
            throughput_mean=("throughput_MBps", "mean"),
        )
        .round(2)
    )
    print(cells.to_string())
    # streaming overhead vs pure download (post_download's download_s column)
    dl = df[df["variant"] == "post_download"].groupby("size_gb")["download_s"].mean()
    st = df[df["variant"] == "streaming"].groupby("size_gb")["total_s"].mean()
    overhead = ((st - dl) / dl * 100).round(1)
    print("\nstreaming-hash overhead vs plain download (%):")
    print(overhead.to_string())
    out = sys.argv[1].replace(".csv", "-summary.csv")
    cells.to_csv(out)
    print(f"\nwritten: {out}")


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    df = pd.read_csv(sys.argv[1])
    if "variant" in df.columns:
        summarize_integrity(df)
    else:
        summarize_matrix(df)


if __name__ == "__main__":
    main()
