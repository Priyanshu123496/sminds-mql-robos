#!/usr/bin/env python3
"""Aggregate monthly validation metrics for XAUUSD V1 profile gating."""

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import List


@dataclass
class MonthRow:
    month_key: str
    from_date: str
    to_date: str
    status: str
    pf: float
    dd_pct: float
    trades: int
    net_profit: float
    gross_profit: float
    gross_loss_abs: float
    balance_ratio: float
    reasons: List[str]
    passed: bool
    run_dir: str


def parse_float(value: str, default: float = math.nan) -> float:
    if value is None:
        return default
    text = str(value).strip()
    if not text:
        return default
    if text.upper() == "INF":
        return math.inf
    try:
        return float(text)
    except ValueError:
        return default


def parse_int(value: str, default: int = 0) -> int:
    if value is None:
        return default
    text = str(value).strip()
    if not text:
        return default
    try:
        return int(float(text))
    except ValueError:
        return default


def median(values: List[float]) -> float:
    clean = [v for v in values if not math.isnan(v) and not math.isinf(v)]
    if not clean:
        return math.nan
    return statistics.median(clean)


def evaluate_row(
    row: dict,
    objective_ratio: float,
    pf_min: float,
    dd_max: float,
    trades_min: int,
) -> MonthRow:
    status = str(row.get("status", "")).strip() or "unknown"
    pf = parse_float(row.get("pf"))
    dd_pct = parse_float(row.get("dd_pct"))
    trades = parse_int(row.get("trades"))
    net_profit = parse_float(row.get("net_profit"), 0.0)
    gross_profit = parse_float(row.get("gross_profit"), 0.0)
    gross_loss_abs = parse_float(row.get("gross_loss_abs"), 0.0)
    balance_ratio = parse_float(row.get("balance_ratio"), math.nan)

    reasons: List[str] = []

    if status != "ok":
        reasons.append(f"status_{status}")

    if math.isnan(balance_ratio) or balance_ratio < objective_ratio:
        reasons.append("target_fail")

    if math.isnan(pf) or pf < pf_min:
        reasons.append("pf_fail")

    if math.isnan(dd_pct) or dd_pct > dd_max:
        reasons.append("dd_fail")

    if trades < trades_min:
        reasons.append("trades_fail")

    passed = len(reasons) == 0

    return MonthRow(
        month_key=str(row.get("month_key", "")),
        from_date=str(row.get("from_date", "")),
        to_date=str(row.get("to_date", "")),
        status=status,
        pf=pf,
        dd_pct=dd_pct,
        trades=trades,
        net_profit=net_profit,
        gross_profit=gross_profit,
        gross_loss_abs=gross_loss_abs,
        balance_ratio=balance_ratio,
        reasons=reasons,
        passed=passed,
        run_dir=str(row.get("run_dir", "")),
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Score monthly validation results")
    parser.add_argument("--input-csv", required=True)
    parser.add_argument("--output-json", required=True)
    parser.add_argument("--output-csv", required=True)
    parser.add_argument("--objective-ratio", type=float, default=1.8)
    parser.add_argument("--pf-min", type=float, default=1.75)
    parser.add_argument("--dd-max", type=float, default=20.0)
    parser.add_argument("--trades-min", type=int, default=20)
    parser.add_argument("--months-pass-min", type=int, default=8)
    parser.add_argument("--months-total", type=int, default=12)
    parser.add_argument("--months-trades-min", type=int, default=10)
    parser.add_argument("--catastrophic-dd-max", type=float, default=30.0)
    parser.add_argument("--determinism-avg-drift", type=float, default=math.nan)
    parser.add_argument("--determinism-max-drift", type=float, default=0.02)
    args = parser.parse_args()

    input_csv = Path(args.input_csv)
    output_json = Path(args.output_json)
    output_csv = Path(args.output_csv)
    output_json.parent.mkdir(parents=True, exist_ok=True)
    output_csv.parent.mkdir(parents=True, exist_ok=True)

    rows: List[MonthRow] = []
    with input_csv.open("r", encoding="ascii", newline="") as f:
        reader = csv.DictReader(f)
        for raw in reader:
            rows.append(
                evaluate_row(
                    raw,
                    objective_ratio=args.objective_ratio,
                    pf_min=args.pf_min,
                    dd_max=args.dd_max,
                    trades_min=args.trades_min,
                )
            )

    months_passed = sum(1 for r in rows if r.passed)
    months_with_trades = sum(1 for r in rows if r.trades >= args.trades_min)
    dd_values = [r.dd_pct for r in rows if not math.isnan(r.dd_pct)]
    pf_values = [r.pf for r in rows if not math.isnan(r.pf) and not math.isinf(r.pf)]
    ratio_values = [r.balance_ratio for r in rows if not math.isnan(r.balance_ratio)]

    worst_month_dd = max(dd_values) if dd_values else math.nan
    median_pf = median(pf_values)
    median_ratio = median(ratio_values)

    determinism_ok = math.isnan(args.determinism_avg_drift) or args.determinism_avg_drift <= args.determinism_max_drift

    production_candidate = (
        months_passed >= args.months_pass_min
        and months_with_trades >= args.months_trades_min
        and (not math.isnan(worst_month_dd) and worst_month_dd <= args.catastrophic_dd_max)
        and determinism_ok
    )

    classification = "production-candidate" if production_candidate else "niche-profile"

    summary = {
        "objective": {
            "monthly_balance_ratio_min": args.objective_ratio,
            "monthly_pf_min": args.pf_min,
            "monthly_dd_max_pct": args.dd_max,
            "monthly_trades_min": args.trades_min,
            "months_pass_min": args.months_pass_min,
            "months_total": args.months_total,
            "months_trades_min": args.months_trades_min,
            "catastrophic_dd_max": args.catastrophic_dd_max,
            "determinism_max_drift": args.determinism_max_drift,
        },
        "classification": classification,
        "months_passed": months_passed,
        "months_total": len(rows),
        "months_with_trades_min": months_with_trades,
        "median_monthly_pf": median_pf,
        "median_monthly_balance_ratio": median_ratio,
        "worst_month_dd_pct": worst_month_dd,
        "determinism_avg_pf_drift": args.determinism_avg_drift,
        "determinism_ok": determinism_ok,
        "months": [asdict(r) for r in rows],
    }

    with output_json.open("w", encoding="ascii") as f:
        json.dump(summary, f, indent=2)

    with output_csv.open("w", encoding="ascii", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(
            [
                "month_key",
                "from_date",
                "to_date",
                "status",
                "pf",
                "dd_pct",
                "trades",
                "net_profit",
                "gross_profit",
                "gross_loss_abs",
                "balance_ratio",
                "passed",
                "reasons",
                "run_dir",
            ]
        )
        for row in rows:
            writer.writerow(
                [
                    row.month_key,
                    row.from_date,
                    row.to_date,
                    row.status,
                    row.pf,
                    row.dd_pct,
                    row.trades,
                    row.net_profit,
                    row.gross_profit,
                    row.gross_loss_abs,
                    row.balance_ratio,
                    "true" if row.passed else "false",
                    ",".join(row.reasons),
                    row.run_dir,
                ]
            )


if __name__ == "__main__":
    main()
