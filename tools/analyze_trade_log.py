#!/usr/bin/env python3
"""Analyze EA trade log CSV and emit monthly/regime diagnostics summaries."""

from __future__ import annotations

import argparse
import csv
import json
import re
from collections import Counter, defaultdict
from dataclasses import dataclass, asdict
from datetime import datetime
from pathlib import Path
from typing import Dict, List


PROFIT_RE = re.compile(r"profit=([-+]?\d+(?:\.\d+)?)")


@dataclass
class TradeBucket:
    trades: int = 0
    wins: int = 0
    losses: int = 0
    gross_profit: float = 0.0
    gross_loss: float = 0.0
    net_profit: float = 0.0

    def update(self, profit: float) -> None:
        self.trades += 1
        self.net_profit += profit
        if profit > 0.0:
            self.wins += 1
            self.gross_profit += profit
        elif profit < 0.0:
            self.losses += 1
            self.gross_loss += profit

    def win_rate_pct(self) -> float:
        if self.trades <= 0:
            return 0.0
        return 100.0 * (self.wins / self.trades)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Analyze XAUUSD_RobustBreakout EA trade log CSV.")
    parser.add_argument("--log", required=True, help="Path to EA log CSV (semicolon-delimited).")
    parser.add_argument(
        "--output-prefix",
        default="outputs/trade_log_analysis",
        help="Output prefix for JSON/CSV artifacts (default: outputs/trade_log_analysis).",
    )
    return parser.parse_args()


def parse_timestamp(value: str) -> datetime | None:
    value = (value or "").strip()
    if not value:
        return None
    for fmt in ("%Y.%m.%d %H:%M:%S", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(value, fmt)
        except ValueError:
            continue
    return None


def parse_profit(reason: str) -> float | None:
    match = PROFIT_RE.search(reason or "")
    if not match:
        return None
    try:
        return float(match.group(1))
    except ValueError:
        return None


def parse_key_value_summary(summary: str) -> Dict[str, str]:
    parsed: Dict[str, str] = {}
    for token in (summary or "").split():
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        parsed[key.strip()] = value.strip()
    return parsed


def is_early_regime(ts: datetime) -> bool:
    return datetime(2025, 8, 1, 0, 0, 0) <= ts <= datetime(2025, 10, 31, 23, 59, 59)


def is_late_regime(ts: datetime) -> bool:
    return datetime(2025, 11, 1, 0, 0, 0) <= ts <= datetime(2026, 2, 28, 23, 59, 59)


def ensure_output_parent(prefix: Path) -> None:
    prefix.parent.mkdir(parents=True, exist_ok=True)


def write_monthly_csv(path: Path, monthly: Dict[str, TradeBucket]) -> None:
    with path.open("w", newline="", encoding="ascii") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "month",
                "trades",
                "wins",
                "losses",
                "win_rate_pct",
                "gross_profit",
                "gross_loss",
                "net_profit",
            ],
        )
        writer.writeheader()
        for month in sorted(monthly):
            bucket = monthly[month]
            writer.writerow(
                {
                    "month": month,
                    "trades": bucket.trades,
                    "wins": bucket.wins,
                    "losses": bucket.losses,
                    "win_rate_pct": round(bucket.win_rate_pct(), 4),
                    "gross_profit": round(bucket.gross_profit, 2),
                    "gross_loss": round(bucket.gross_loss, 2),
                    "net_profit": round(bucket.net_profit, 2),
                }
            )


def write_gate_csv(path: Path, gate_rows: List[Dict[str, str]]) -> None:
    all_keys = set()
    for row in gate_rows:
        all_keys.update(row.keys())

    fieldnames = ["timestamp", "label"] + sorted(k for k in all_keys if k not in {"timestamp", "label"})
    with path.open("w", newline="", encoding="ascii") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in gate_rows:
            writer.writerow(row)


def bucket_to_payload(bucket: TradeBucket) -> Dict[str, float | int]:
    return {
        "trades": bucket.trades,
        "wins": bucket.wins,
        "losses": bucket.losses,
        "win_rate_pct": round(bucket.win_rate_pct(), 4),
        "gross_profit": round(bucket.gross_profit, 2),
        "gross_loss": round(bucket.gross_loss, 2),
        "net_profit": round(bucket.net_profit, 2),
    }


def main() -> int:
    args = parse_args()
    log_path = Path(args.log)
    if not log_path.exists():
        raise SystemExit(f"log file not found: {log_path}")

    event_counts: Counter[str] = Counter()
    monthly: Dict[str, TradeBucket] = defaultdict(TradeBucket)
    overall = TradeBucket()
    early = TradeBucket()
    late = TradeBucket()
    gate_rows: List[Dict[str, str]] = []
    regime_rows: List[Dict[str, str]] = []

    with log_path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle, delimiter=";")
        for row in reader:
            event = (row.get("event") or "").strip()
            timestamp = parse_timestamp(row.get("timestamp", ""))
            event_counts[event] += 1

            if event == "GATE_STATS":
                parsed = parse_key_value_summary(row.get("comment", ""))
                parsed["timestamp"] = row.get("timestamp", "")
                parsed["label"] = row.get("reason", "")
                gate_rows.append(parsed)
                continue

            if event == "REGIME_STATS":
                parsed = parse_key_value_summary(row.get("comment", ""))
                parsed["timestamp"] = row.get("timestamp", "")
                parsed["label"] = row.get("reason", "")
                regime_rows.append(parsed)
                continue

            if event != "DEAL_OUT" or timestamp is None:
                continue

            profit = parse_profit(row.get("reason", ""))
            if profit is None:
                continue

            overall.update(profit)
            month_key = timestamp.strftime("%Y-%m")
            monthly[month_key].update(profit)

            if is_early_regime(timestamp):
                early.update(profit)
            elif is_late_regime(timestamp):
                late.update(profit)

    latest_gate = gate_rows[-1] if gate_rows else {}
    latest_regime = regime_rows[-1] if regime_rows else {}
    reject_composition = {k: v for k, v in latest_gate.items() if k.startswith("r_")}

    monthly_payload = [
        {"month": month, **bucket_to_payload(monthly[month])}
        for month in sorted(monthly)
    ]

    payload = {
        "log_path": str(log_path),
        "event_counts": dict(event_counts),
        "trade_metrics": bucket_to_payload(overall),
        "monthly_metrics": monthly_payload,
        "regime_metrics": {
            "early_2025_08_to_2025_10": bucket_to_payload(early),
            "late_2025_11_to_2026_02": bucket_to_payload(late),
        },
        "gate_stats_rows": len(gate_rows),
        "gate_stats_latest": latest_gate,
        "reject_composition_latest": reject_composition,
        "regime_stats_rows": len(regime_rows),
        "regime_stats_latest": latest_regime,
    }

    prefix = Path(args.output_prefix)
    ensure_output_parent(prefix)

    json_path = prefix.with_suffix(".json")
    monthly_csv_path = prefix.with_name(prefix.name + "_monthly.csv")
    gate_csv_path = prefix.with_name(prefix.name + "_gate_stats.csv")

    with json_path.open("w", encoding="ascii") as handle:
        json.dump(payload, handle, indent=2)

    write_monthly_csv(monthly_csv_path, monthly)
    write_gate_csv(gate_csv_path, gate_rows)

    print(f"wrote {json_path}")
    print(f"wrote {monthly_csv_path}")
    print(f"wrote {gate_csv_path}")
    print(json.dumps(payload["trade_metrics"], indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
