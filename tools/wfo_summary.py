#!/usr/bin/env python3
"""Aggregate MT5 XML reports into WFO acceptance summary JSON/CSV."""

from __future__ import annotations

import argparse
import csv
import json
import re
import statistics
import sys
from dataclasses import dataclass, asdict
from pathlib import Path
import xml.etree.ElementTree as ET


FLOAT_RE = r"(-?\d+(?:[\.,]\d+)?)"


@dataclass
class ReportMetrics:
    path: str
    split: str
    profit_factor: float | None
    drawdown_pct: float | None
    trades: int | None
    net_profit: float | None
    pf_degradation_from_best_is_pct: float | None = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build walk-forward summary from MT5 XML reports.")
    parser.add_argument("--reports-dir", required=True, help="Directory containing MT5 XML reports.")
    parser.add_argument("--glob", default="*.xml", help="Glob to find report files (default: *.xml).")
    parser.add_argument(
        "--output-prefix",
        default="outputs/wfo_summary",
        help="Output prefix for .csv and .json files (default: outputs/wfo_summary).",
    )
    parser.add_argument("--is-pf-min", type=float, default=2.5)
    parser.add_argument("--oos-pf-median-min", type=float, default=1.6)
    parser.add_argument("--oos-pf-fold-min", type=float, default=1.2)
    parser.add_argument("--holdout-pf-min", type=float, default=1.4)
    parser.add_argument("--max-dd-pct", type=float, default=15.0)
    parser.add_argument("--min-trades", type=int, default=300)
    parser.add_argument("--stress-pf-degrade-max-pct", type=float, default=25.0)
    return parser.parse_args()


def normalize_number(value: str) -> float | None:
    if not value:
        return None
    cleaned = value.replace(" ", "").replace("%", "")
    if cleaned.count(",") == 1 and cleaned.count(".") == 0:
        cleaned = cleaned.replace(",", ".")
    elif cleaned.count(",") > 0 and cleaned.count(".") > 0:
        cleaned = cleaned.replace(",", "")
    try:
        return float(cleaned)
    except ValueError:
        return None


def extract_first(text: str, patterns: list[str]) -> float | None:
    for pattern in patterns:
        match = re.search(pattern, text, flags=re.IGNORECASE)
        if match:
            return normalize_number(match.group(1))
    return None


def classify_split(path: Path) -> str:
    name = path.stem.lower()
    if "holdout" in name or "final" in name:
        return "holdout"
    if "stress" in name:
        return "stress"
    if "oos" in name or "forward" in name:
        return "oos"
    if "is" in name or "insample" in name or "train" in name:
        return "is"
    return "unknown"


def parse_report(path: Path) -> ReportMetrics:
    split = classify_split(path)
    text = ""

    try:
        root = ET.parse(path).getroot()
        text = " ".join(fragment.strip() for fragment in root.itertext() if fragment and fragment.strip())
    except ET.ParseError:
        # Keep text empty, resulting fields become None.
        pass

    pf = extract_first(
        text,
        [
            rf"profit\s*factor\D+{FLOAT_RE}",
            rf"pf\D+{FLOAT_RE}",
        ],
    )
    drawdown_pct = extract_first(
        text,
        [
            rf"balance\s*drawdown\s*relative\D+{FLOAT_RE}\s*%",
            rf"max(?:imal)?\s*drawdown\D+{FLOAT_RE}\s*%",
            rf"drawdown\D+{FLOAT_RE}\s*%",
        ],
    )
    trades_val = extract_first(
        text,
        [
            rf"total\s*trades\D+{FLOAT_RE}",
            rf"trades\D+{FLOAT_RE}",
        ],
    )
    net_profit = extract_first(
        text,
        [
            rf"net\s*profit\D+{FLOAT_RE}",
            rf"total\s*net\s*profit\D+{FLOAT_RE}",
        ],
    )

    trades = int(trades_val) if trades_val is not None else None

    return ReportMetrics(
        path=str(path),
        split=split,
        profit_factor=pf,
        drawdown_pct=drawdown_pct,
        trades=trades,
        net_profit=net_profit,
    )


def ensure_output_parent(prefix: Path) -> None:
    prefix.parent.mkdir(parents=True, exist_ok=True)


def apply_stress_degradation(metrics: list[ReportMetrics]) -> None:
    is_pfs = [m.profit_factor for m in metrics if m.split == "is" and m.profit_factor is not None]
    if not is_pfs:
        return

    best_is_pf = max(is_pfs)
    if best_is_pf <= 0:
        return

    for item in metrics:
        if item.profit_factor is None:
            continue
        degrade = (best_is_pf - item.profit_factor) / best_is_pf * 100.0
        item.pf_degradation_from_best_is_pct = degrade


def check_acceptance(metrics: list[ReportMetrics], args: argparse.Namespace) -> dict:
    is_rows = [m for m in metrics if m.split == "is"]
    oos_rows = [m for m in metrics if m.split == "oos"]
    holdout_rows = [m for m in metrics if m.split == "holdout"]
    stress_rows = [m for m in metrics if m.split == "stress"]

    def is_valid(m: ReportMetrics) -> bool:
        return (
            m.profit_factor is not None
            and m.drawdown_pct is not None
            and m.trades is not None
        )

    is_pass = False
    if is_rows and all(is_valid(m) for m in is_rows):
        is_pass = all(
            m.profit_factor > args.is_pf_min
            and m.drawdown_pct <= args.max_dd_pct
            and m.trades >= args.min_trades
            for m in is_rows
        )

    oos_pass = False
    if oos_rows and all(m.profit_factor is not None for m in oos_rows):
        pf_values = [m.profit_factor for m in oos_rows if m.profit_factor is not None]
        median_pf = statistics.median(pf_values)
        min_pf = min(pf_values)
        dd_ok = all((m.drawdown_pct is None or m.drawdown_pct <= args.max_dd_pct) for m in oos_rows)
        oos_pass = median_pf >= args.oos_pf_median_min and min_pf >= args.oos_pf_fold_min and dd_ok
    else:
        median_pf = None
        min_pf = None

    holdout_pass = False
    if holdout_rows and all(m.profit_factor is not None for m in holdout_rows):
        holdout_pass = all(
            m.profit_factor >= args.holdout_pf_min
            and (m.drawdown_pct is None or m.drawdown_pct <= args.max_dd_pct)
            for m in holdout_rows
        )

    stress_pass = None
    if stress_rows:
        stress_pass = True
        for m in stress_rows:
            if m.net_profit is not None and m.net_profit <= 0:
                stress_pass = False
                break
            if (
                m.pf_degradation_from_best_is_pct is not None
                and m.pf_degradation_from_best_is_pct > args.stress_pf_degrade_max_pct
            ):
                stress_pass = False
                break

    return {
        "is_pass": is_pass,
        "oos_pass": oos_pass,
        "holdout_pass": holdout_pass,
        "stress_pass": stress_pass,
        "oos_median_pf": median_pf,
        "oos_min_pf": min_pf,
        "counts": {
            "is": len(is_rows),
            "oos": len(oos_rows),
            "holdout": len(holdout_rows),
            "stress": len(stress_rows),
            "total": len(metrics),
        },
        "overall_pass": bool(is_pass and oos_pass and holdout_pass and (stress_pass in (True, None))),
    }


def write_csv(path: Path, metrics: list[ReportMetrics]) -> None:
    with path.open("w", newline="", encoding="ascii") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "path",
                "split",
                "profit_factor",
                "drawdown_pct",
                "trades",
                "net_profit",
                "pf_degradation_from_best_is_pct",
            ],
        )
        writer.writeheader()
        for row in metrics:
            writer.writerow(asdict(row))


def main() -> int:
    args = parse_args()
    reports_dir = Path(args.reports_dir)

    if not reports_dir.exists() or not reports_dir.is_dir():
        print(f"reports directory not found: {reports_dir}", file=sys.stderr)
        return 2

    files = sorted(reports_dir.glob(args.glob))
    if not files:
        print("no report files found", file=sys.stderr)
        return 3

    metrics = [parse_report(path) for path in files]
    apply_stress_degradation(metrics)
    acceptance = check_acceptance(metrics, args)

    prefix = Path(args.output_prefix)
    ensure_output_parent(prefix)

    csv_path = prefix.with_suffix(".csv")
    json_path = prefix.with_suffix(".json")

    write_csv(csv_path, metrics)

    payload = {
        "acceptance": acceptance,
        "thresholds": {
            "is_pf_min": args.is_pf_min,
            "oos_pf_median_min": args.oos_pf_median_min,
            "oos_pf_fold_min": args.oos_pf_fold_min,
            "holdout_pf_min": args.holdout_pf_min,
            "max_dd_pct": args.max_dd_pct,
            "min_trades": args.min_trades,
            "stress_pf_degrade_max_pct": args.stress_pf_degrade_max_pct,
        },
        "reports": [asdict(item) for item in metrics],
    }

    with json_path.open("w", encoding="ascii") as handle:
        json.dump(payload, handle, indent=2)

    print(f"wrote {csv_path}")
    print(f"wrote {json_path}")
    print(json.dumps(acceptance, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
