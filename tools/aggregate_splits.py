#!/usr/bin/env python3
"""Aggregate MT5 split runs and evaluate PF/DD acceptance gates."""

from __future__ import annotations

import argparse
import csv
import json
import re
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any, Dict, List, Optional
import xml.etree.ElementTree as ET


FLOAT_RE = r"(-?\d+(?:[\.,]\d+)?)"


@dataclass
class RunResult:
    run_label: str
    split_tag: str
    split_class: str
    from_date: str
    to_date: str
    profit_factor: Optional[float]
    drawdown_pct: Optional[float]
    trades: Optional[int]
    net_profit: Optional[float]
    report_xml: str
    report_html: str
    trade_log_csv: str
    metrics_source: str
    config_sha256: str
    duration_seconds: Optional[float]
    terminal_exit_code: Optional[int]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Aggregate MT5 split run outputs and check acceptance criteria.")
    parser.add_argument("--runs-dir", required=True, help="Root directory containing run subfolders.")
    parser.add_argument(
        "--output-prefix",
        default="outputs/split_summary",
        help="Output prefix for CSV/JSON (default: outputs/split_summary).",
    )
    parser.add_argument("--combined-pf-min", type=float, default=2.0)
    parser.add_argument("--combined-dd-max", type=float, default=15.0)
    parser.add_argument("--combined-trades-min", type=int, default=300)
    parser.add_argument("--regime-pf-min", type=float, default=1.2)
    parser.add_argument("--regime-dd-max", type=float, default=20.0)
    parser.add_argument("--wfo-pf-min", type=float, default=1.4)
    parser.add_argument("--wfo-pass-ratio-min", type=float, default=0.60)
    parser.add_argument("--wfo-catastrophic-pf", type=float, default=1.0)
    parser.add_argument("--wfo-catastrophic-dd", type=float, default=25.0)
    return parser.parse_args()


def normalize_number(value: str) -> Optional[float]:
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


def extract_first(text: str, patterns: List[str]) -> Optional[float]:
    for pattern in patterns:
        match = re.search(pattern, text, flags=re.IGNORECASE)
        if match:
            return normalize_number(match.group(1))
    return None


def extract_xml_numeric(root: ET.Element, tag_names: List[str]) -> Optional[float]:
    for name in tag_names:
        node = root.find(f".//{name}")
        if node is not None and node.text:
            value = normalize_number(node.text.strip())
            if value is not None:
                return value
    return None


def parse_report_metrics(report_xml: Path) -> Dict[str, Optional[float]]:
    text = ""
    root: Optional[ET.Element] = None
    try:
        root = ET.parse(report_xml).getroot()
        text = " ".join(fragment.strip() for fragment in root.itertext() if fragment and fragment.strip())
    except ET.ParseError:
        text = ""

    pf = extract_xml_numeric(root, ["profit_factor", "profitfactor"]) if root is not None else None
    if pf is None:
        pf = extract_first(
        text,
        [
            rf"profit\s*factor\D+{FLOAT_RE}",
            rf"\bpf\D+{FLOAT_RE}",
        ],
        )

    dd_pct = extract_xml_numeric(root, ["drawdown_pct", "max_drawdown_pct", "balance_drawdown_relative_pct"]) if root is not None else None
    if dd_pct is None:
        dd_pct = extract_first(
        text,
        [
            rf"balance\s*drawdown\s*relative\D+{FLOAT_RE}\s*%",
            rf"equity\s*drawdown\s*relative\D+{FLOAT_RE}\s*%",
            rf"drawdown\D+{FLOAT_RE}\s*%",
        ],
        )

    trades_val = extract_xml_numeric(root, ["trades", "total_trades"]) if root is not None else None
    if trades_val is None:
        trades_val = extract_first(
        text,
        [
            rf"total\s*trades\D+{FLOAT_RE}",
            rf"\btrades\D+{FLOAT_RE}",
        ],
        )

    net_profit = extract_xml_numeric(root, ["net_profit", "total_net_profit"]) if root is not None else None
    if net_profit is None:
        net_profit = extract_first(
        text,
        [
            rf"total\s*net\s*profit\D+{FLOAT_RE}",
            rf"net\s*profit\D+{FLOAT_RE}",
        ],
        )

    trades = int(trades_val) if trades_val is not None else None
    return {
        "profit_factor": pf,
        "drawdown_pct": dd_pct,
        "trades": trades,
        "net_profit": net_profit,
    }


def parse_profit_from_reason(reason: str) -> Optional[float]:
    match = re.search(r"profit=([-+]?\d+(?:\.\d+)?)", reason or "", flags=re.IGNORECASE)
    if not match:
        return None
    try:
        return float(match.group(1))
    except ValueError:
        return None


def parse_float(value: str) -> Optional[float]:
    if value is None:
        return None
    try:
        return float(str(value).replace(",", "").strip())
    except ValueError:
        return None


def parse_trade_log_metrics(trade_log_csv: Path) -> Dict[str, Optional[float]]:
    gross_profit = 0.0
    gross_loss_abs = 0.0
    net_profit = 0.0
    trades = 0

    max_dd_pct = 0.0
    peak_balance: Optional[float] = None

    with trade_log_csv.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle, delimiter=";")
        for row in reader:
            balance = parse_float(row.get("balance", ""))
            if balance is not None:
                if peak_balance is None or balance > peak_balance:
                    peak_balance = balance
                if peak_balance and peak_balance > 0.0:
                    dd_pct = (peak_balance - balance) / peak_balance * 100.0
                    if dd_pct > max_dd_pct:
                        max_dd_pct = dd_pct

            if (row.get("event") or "").strip() != "DEAL_OUT":
                continue

            profit = parse_profit_from_reason(row.get("reason", ""))
            if profit is None:
                continue

            trades += 1
            net_profit += profit
            if profit > 0.0:
                gross_profit += profit
            elif profit < 0.0:
                gross_loss_abs += abs(profit)

    pf: Optional[float]
    if gross_loss_abs > 0.0:
        pf = gross_profit / gross_loss_abs
    elif gross_profit > 0.0:
        pf = float("inf")
    else:
        pf = None

    return {
        "profit_factor": pf,
        "drawdown_pct": max_dd_pct if peak_balance is not None else None,
        "trades": trades if trades > 0 else 0,
        "net_profit": net_profit,
    }


def classify_split(split_tag: str, run_label: str) -> str:
    token = f"{split_tag} {run_label}".lower()
    if any(key in token for key in ["regime", "nov2025", "2025-11", "hard_oos"]):
        return "regime_oos"
    if any(key in token for key in ["wfo", "fold", "forward", "oos", "test"]):
        return "wfo"
    if any(key in token for key in ["combined", "full", "all", "is", "train", "insample"]):
        return "combined"
    return "unknown"


def load_run_result(metadata_path: Path) -> Optional[RunResult]:
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None

    run_dir = metadata_path.parent
    report_xml = metadata.get("report_xml") or ""
    report_xml_path: Optional[Path] = None
    if report_xml:
        candidate = Path(report_xml)
        if candidate.exists() and candidate.is_file():
            report_xml_path = candidate

    if report_xml_path is None:
        candidates = [path for path in sorted(run_dir.glob("mt5_report*.xml")) if path.is_file()]
        if candidates:
            report_xml_path = candidates[-1]

    trade_log_csv = str(metadata.get("trade_log_csv", ""))
    trade_log_path = Path(trade_log_csv) if trade_log_csv else Path("")

    metrics_source = "none"
    metrics: Dict[str, Optional[float]]
    if report_xml_path is not None and report_xml_path.exists() and report_xml_path.is_file():
        metrics = parse_report_metrics(report_xml_path)
        metrics_source = "xml"
    elif trade_log_path.exists():
        metrics = parse_trade_log_metrics(trade_log_path)
        metrics_source = "trade_log"
    else:
        return None

    split_tag = str(metadata.get("split_tag", ""))
    run_label = str(metadata.get("run_label", run_dir.name))

    return RunResult(
        run_label=run_label,
        split_tag=split_tag,
        split_class=classify_split(split_tag, run_label),
        from_date=str(metadata.get("from_date", "")),
        to_date=str(metadata.get("to_date", "")),
        profit_factor=metrics["profit_factor"],
        drawdown_pct=metrics["drawdown_pct"],
        trades=metrics["trades"],
        net_profit=metrics["net_profit"],
        report_xml=str(report_xml_path) if report_xml_path is not None else "",
        report_html=str(metadata.get("report_html", "")),
        trade_log_csv=trade_log_csv,
        metrics_source=metrics_source,
        config_sha256=str(metadata.get("config_sha256", "")),
        duration_seconds=float(metadata["duration_seconds"]) if metadata.get("duration_seconds") is not None else None,
        terminal_exit_code=int(metadata["terminal_exit_code"]) if metadata.get("terminal_exit_code") is not None else None,
    )


def find_best(rows: List[RunResult]) -> Optional[RunResult]:
    scored = [r for r in rows if r.profit_factor is not None]
    if not scored:
        return None
    return max(scored, key=lambda row: row.profit_factor or float("-inf"))


def is_combined_pass(row: RunResult, args: argparse.Namespace) -> bool:
    if row.profit_factor is None or row.drawdown_pct is None or row.trades is None:
        return False
    return (
        row.profit_factor > args.combined_pf_min
        and row.drawdown_pct <= args.combined_dd_max
        and row.trades >= args.combined_trades_min
    )


def is_regime_pass(row: RunResult, args: argparse.Namespace) -> bool:
    if row.profit_factor is None or row.drawdown_pct is None:
        return False
    return row.profit_factor >= args.regime_pf_min and row.drawdown_pct <= args.regime_dd_max


def evaluate_acceptance(results: List[RunResult], args: argparse.Namespace) -> Dict[str, Any]:
    combined_rows = [r for r in results if r.split_class == "combined"]
    regime_rows = [r for r in results if r.split_class == "regime_oos"]
    wfo_rows = [r for r in results if r.split_class == "wfo"]

    combined_best = find_best(combined_rows)
    regime_best = find_best(regime_rows)

    combined_pass = any(is_combined_pass(row, args) for row in combined_rows)
    regime_pass = any(is_regime_pass(row, args) for row in regime_rows)

    wfo_pass_ratio = 0.0
    wfo_no_catastrophic = False
    wfo_pass = False

    if wfo_rows:
        pass_count = sum(1 for row in wfo_rows if row.profit_factor is not None and row.profit_factor >= args.wfo_pf_min)
        wfo_pass_ratio = pass_count / len(wfo_rows)
        wfo_no_catastrophic = all(
            not (
                row.profit_factor is not None
                and row.drawdown_pct is not None
                and row.profit_factor < args.wfo_catastrophic_pf
                and row.drawdown_pct > args.wfo_catastrophic_dd
            )
            for row in wfo_rows
        )
        wfo_pass = wfo_pass_ratio >= args.wfo_pass_ratio_min and wfo_no_catastrophic

    return {
        "combined_pass": combined_pass,
        "regime_oos_pass": regime_pass,
        "wfo_stability_pass": wfo_pass,
        "overall_pass": bool(combined_pass and regime_pass and wfo_pass),
        "counts": {
            "combined": len(combined_rows),
            "regime_oos": len(regime_rows),
            "wfo": len(wfo_rows),
            "unknown": len([r for r in results if r.split_class == "unknown"]),
            "total": len(results),
        },
        "wfo_pass_ratio": round(wfo_pass_ratio, 4),
        "wfo_no_catastrophic_fold": wfo_no_catastrophic,
        "combined_best": asdict(combined_best) if combined_best else None,
        "regime_best": asdict(regime_best) if regime_best else None,
    }


def ensure_output_parent(prefix: Path) -> None:
    prefix.parent.mkdir(parents=True, exist_ok=True)


def write_csv(path: Path, results: List[RunResult]) -> None:
    with path.open("w", newline="", encoding="ascii") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "run_label",
                "split_tag",
                "split_class",
                "from_date",
                "to_date",
                "profit_factor",
                "drawdown_pct",
                "trades",
                "net_profit",
                "report_xml",
                "report_html",
                "trade_log_csv",
                "metrics_source",
                "config_sha256",
                "duration_seconds",
                "terminal_exit_code",
            ],
        )
        writer.writeheader()
        for row in results:
            writer.writerow(asdict(row))


def main() -> int:
    args = parse_args()
    runs_dir = Path(args.runs_dir)
    if not runs_dir.exists() or not runs_dir.is_dir():
        raise SystemExit(f"runs directory not found: {runs_dir}")

    metadata_files = sorted(runs_dir.glob("**/run_metadata.json"))
    if not metadata_files:
        raise SystemExit("no run_metadata.json files found under runs directory")

    results: List[RunResult] = []
    for meta_path in metadata_files:
        parsed = load_run_result(meta_path)
        if parsed is not None:
            results.append(parsed)

    if not results:
        raise SystemExit("no valid split runs with XML reports were found")

    acceptance = evaluate_acceptance(results, args)

    prefix = Path(args.output_prefix)
    ensure_output_parent(prefix)
    csv_path = prefix.with_suffix(".csv")
    json_path = prefix.with_suffix(".json")

    write_csv(csv_path, results)

    payload = {
        "acceptance": acceptance,
        "thresholds": {
            "combined_pf_min": args.combined_pf_min,
            "combined_dd_max": args.combined_dd_max,
            "combined_trades_min": args.combined_trades_min,
            "regime_pf_min": args.regime_pf_min,
            "regime_dd_max": args.regime_dd_max,
            "wfo_pf_min": args.wfo_pf_min,
            "wfo_pass_ratio_min": args.wfo_pass_ratio_min,
            "wfo_catastrophic_pf": args.wfo_catastrophic_pf,
            "wfo_catastrophic_dd": args.wfo_catastrophic_dd,
        },
        "runs": [asdict(row) for row in results],
    }

    with json_path.open("w", encoding="ascii") as handle:
        json.dump(payload, handle, indent=2)

    print(f"wrote {csv_path}")
    print(f"wrote {json_path}")
    print(json.dumps(acceptance, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
