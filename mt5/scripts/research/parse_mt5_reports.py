#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import sqlite3
from pathlib import Path
from typing import Dict, List

from common import parse_mt5_report, reason_for_gross_loss


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Parse MT5 HTML reports into CSV and optional SQLite backtest_runs.")
    parser.add_argument("--reports-dir", required=True)
    parser.add_argument("--glob", default="*.htm")
    parser.add_argument("--output-csv", required=True)
    parser.add_argument("--run-id", default="")
    parser.add_argument("--candidate-id", default="")
    parser.add_argument("--period-type", default="Unknown")
    parser.add_argument("--period-label", default="Unknown")
    parser.add_argument("--from-date", default="")
    parser.add_argument("--to-date", default="")
    parser.add_argument("--db-path", default="")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    reports_dir = Path(args.reports_dir)
    out_csv = Path(args.output_csv)
    out_csv.parent.mkdir(parents=True, exist_ok=True)

    reports = sorted(reports_dir.glob(args.glob))
    rows: List[Dict[str, object]] = []
    for report in reports:
        m = parse_mt5_report(report)
        rows.append(
            {
                "RunId": args.run_id,
                "CandidateId": args.candidate_id,
                "PeriodType": args.period_type,
                "PeriodLabel": args.period_label,
                "FromDate": args.from_date,
                "ToDate": args.to_date,
                "NetProfit": round(m.net_profit, 2),
                "GrossProfit": round(m.gross_profit, 2),
                "GrossLoss": round(m.gross_loss, 2),
                "TotalTrades": m.total_trades,
                "ProfitFactor": round(m.profit_factor, 4),
                "ExpectedPayoff": round(m.expected_payoff, 4),
                "MaxDrawdownAbs": round(m.max_drawdown_abs, 2),
                "MaxDrawdownPct": round(m.max_drawdown_pct, 4),
                "WinRatePct": round(m.win_rate_pct, 4),
                "AvgWin": round(m.avg_win, 4),
                "AvgLoss": round(m.avg_loss, 4),
                "ReportFile": str(report),
                "Status": m.status,
                "ReasonForGrossLoss": reason_for_gross_loss(m),
            }
        )

    fieldnames = [
        "RunId",
        "CandidateId",
        "PeriodType",
        "PeriodLabel",
        "FromDate",
        "ToDate",
        "NetProfit",
        "GrossProfit",
        "GrossLoss",
        "TotalTrades",
        "ProfitFactor",
        "ExpectedPayoff",
        "MaxDrawdownAbs",
        "MaxDrawdownPct",
        "WinRatePct",
        "AvgWin",
        "AvgLoss",
        "ReportFile",
        "Status",
        "ReasonForGrossLoss",
    ]
    with out_csv.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    if args.db_path:
        conn = sqlite3.connect(args.db_path)
        try:
            conn.executemany(
                """
                INSERT INTO backtest_runs (
                    run_id, candidate_id, period_type, period_label,
                    from_date, to_date, net_profit, gross_profit, gross_loss,
                    profit_factor, max_dd_pct, trades, report_file, status
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    (
                        str(r["RunId"]),
                        str(r["CandidateId"]),
                        str(r["PeriodType"]),
                        str(r["PeriodLabel"]),
                        str(r["FromDate"]),
                        str(r["ToDate"]),
                        float(r["NetProfit"]),
                        float(r["GrossProfit"]),
                        float(r["GrossLoss"]),
                        float(r["ProfitFactor"]),
                        float(r["MaxDrawdownPct"]),
                        int(r["TotalTrades"]),
                        str(r["ReportFile"]),
                        str(r["Status"]),
                    )
                    for r in rows
                ],
            )
            conn.commit()
        finally:
            conn.close()

    print(f"Parsed reports: {len(rows)}")
    print(f"Output CSV: {out_csv}")


if __name__ == "__main__":
    main()
