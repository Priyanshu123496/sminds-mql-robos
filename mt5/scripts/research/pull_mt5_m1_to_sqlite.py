#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import datetime as dt
import sqlite3
from pathlib import Path
from typing import Dict, List, Tuple

from common import DEFAULT_TERMINAL_PATH, dump_json, ensure_dir, utc_now_iso


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Pull MT5 M1 bars into SQLite.")
    parser.add_argument("--symbol", default="XAUUSD")
    parser.add_argument("--from-date", default="2021-01-01")
    parser.add_argument("--to-date", default="2025-12-31")
    parser.add_argument("--terminal-path", default=str(DEFAULT_TERMINAL_PATH))
    parser.add_argument("--run-dir", required=True, help="Run folder under mt5/research_runs/<RUN_ID>.")
    parser.add_argument("--db-path", default="", help="Optional custom sqlite path.")
    parser.add_argument("--source-terminal", default="MT5-terminal64")
    return parser.parse_args()


def create_schema(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS bars_m1 (
            symbol TEXT NOT NULL,
            ts_server TEXT NOT NULL,
            open REAL NOT NULL,
            high REAL NOT NULL,
            low REAL NOT NULL,
            close REAL NOT NULL,
            tick_volume INTEGER NOT NULL,
            spread INTEGER NOT NULL,
            real_volume INTEGER NOT NULL,
            source_terminal TEXT NOT NULL,
            ingested_at TEXT NOT NULL,
            PRIMARY KEY (symbol, ts_server)
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS feature_regime_daily (
            symbol TEXT NOT NULL,
            day TEXT NOT NULL,
            atr14 REAL NOT NULL,
            adx14 REAL NOT NULL,
            range_pct REAL NOT NULL,
            session_bucket TEXT NOT NULL,
            trend_state TEXT NOT NULL,
            whipsaw_score REAL NOT NULL,
            PRIMARY KEY (symbol, day)
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS backtest_runs (
            run_id TEXT NOT NULL,
            candidate_id TEXT NOT NULL,
            period_type TEXT NOT NULL,
            period_label TEXT NOT NULL,
            from_date TEXT NOT NULL,
            to_date TEXT NOT NULL,
            net_profit REAL NOT NULL,
            gross_profit REAL NOT NULL,
            gross_loss REAL NOT NULL,
            profit_factor REAL NOT NULL,
            max_dd_pct REAL NOT NULL,
            trades INTEGER NOT NULL,
            report_file TEXT NOT NULL,
            status TEXT NOT NULL
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS candidates (
            candidate_id TEXT PRIMARY KEY,
            ea_file TEXT NOT NULL,
            trade_mode TEXT NOT NULL,
            tf TEXT NOT NULL,
            fast INTEGER NOT NULL,
            slow INTEGER NOT NULL,
            filter INTEGER NOT NULL,
            use_adx INTEGER NOT NULL,
            adx_period INTEGER NOT NULL,
            min_adx REAL NOT NULL,
            use_atr INTEGER NOT NULL,
            atr_period INTEGER NOT NULL,
            min_atr REAL NOT NULL,
            session_filter TEXT NOT NULL,
            cooldown_bars INTEGER NOT NULL,
            sl_atr REAL NOT NULL,
            tp_atr REAL NOT NULL,
            score_stage1 REAL NOT NULL DEFAULT 0,
            score_stage2 REAL NOT NULL DEFAULT 0,
            accepted INTEGER NOT NULL DEFAULT 0
        )
        """
    )
    conn.execute("CREATE INDEX IF NOT EXISTS idx_bars_m1_symbol_ts ON bars_m1(symbol, ts_server)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_bars_m1_ts ON bars_m1(ts_server)")
    conn.commit()


def generate_day_ranges(start: dt.date, end: dt.date) -> List[Tuple[dt.datetime, dt.datetime]]:
    ranges: List[Tuple[dt.datetime, dt.datetime]] = []
    cur = start
    while cur <= end:
        day_start = dt.datetime(cur.year, cur.month, cur.day, 0, 0, 0, tzinfo=dt.UTC)
        day_end = day_start + dt.timedelta(days=1)
        ranges.append((day_start, day_end))
        cur += dt.timedelta(days=1)
    return ranges


def insert_rates(
    conn: sqlite3.Connection,
    symbol: str,
    rates,
    range_start: dt.datetime,
    range_end: dt.datetime,
    source_terminal: str,
) -> int:
    if rates is None or len(rates) == 0:
        return 0

    ingested_at = utc_now_iso()
    rows = []
    for r in rates:
        ts_dt = dt.datetime.fromtimestamp(int(r["time"]), dt.UTC)
        if ts_dt < range_start or ts_dt >= range_end:
            continue
        ts = ts_dt.strftime("%Y-%m-%d %H:%M:%S")
        rows.append(
            (
                symbol,
                ts,
                float(r["open"]),
                float(r["high"]),
                float(r["low"]),
                float(r["close"]),
                int(r["tick_volume"]),
                int(r["spread"]),
                int(r["real_volume"]),
                source_terminal,
                ingested_at,
            )
        )

    if not rows:
        return 0

    conn.executemany(
        """
        INSERT INTO bars_m1 (
            symbol, ts_server, open, high, low, close,
            tick_volume, spread, real_volume, source_terminal, ingested_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(symbol, ts_server) DO UPDATE SET
            open=excluded.open,
            high=excluded.high,
            low=excluded.low,
            close=excluded.close,
            tick_volume=excluded.tick_volume,
            spread=excluded.spread,
            real_volume=excluded.real_volume,
            source_terminal=excluded.source_terminal,
            ingested_at=excluded.ingested_at
        """,
        rows,
    )
    conn.commit()
    return len(rows)


def detect_gaps(conn: sqlite3.Connection, symbol: str) -> List[Tuple[str, str, int]]:
    cur = conn.execute(
        """
        SELECT ts_server
        FROM bars_m1
        WHERE symbol = ?
        ORDER BY ts_server
        """,
        (symbol,),
    )
    rows = [r[0] for r in cur.fetchall()]
    gaps: List[Tuple[str, str, int]] = []
    if len(rows) < 2:
        return gaps

    prev = dt.datetime.strptime(rows[0], "%Y-%m-%d %H:%M:%S")
    for ts_text in rows[1:]:
        cur_ts = dt.datetime.strptime(ts_text, "%Y-%m-%d %H:%M:%S")
        diff_min = int((cur_ts - prev).total_seconds() // 60)
        if diff_min > 1:
            gaps.append(
                (
                    prev.strftime("%Y-%m-%d %H:%M:%S"),
                    cur_ts.strftime("%Y-%m-%d %H:%M:%S"),
                    diff_min - 1,
                )
            )
        prev = cur_ts
    return gaps


def main() -> None:
    args = parse_args()

    run_dir = Path(args.run_dir)
    data_dir = ensure_dir(run_dir / "data")
    summaries_dir = ensure_dir(run_dir / "summaries")
    logs_dir = ensure_dir(run_dir / "logs")

    db_path = Path(args.db_path) if args.db_path else (data_dir / "xauusd_m1.sqlite")
    ensure_dir(db_path.parent)

    start = dt.datetime.strptime(args.from_date, "%Y-%m-%d").date()
    end = dt.datetime.strptime(args.to_date, "%Y-%m-%d").date()
    if start > end:
        raise ValueError("--from-date must be <= --to-date")

    try:
        import MetaTrader5 as mt5  # type: ignore
    except ImportError as exc:
        raise RuntimeError("MetaTrader5 package is not installed. Install with: pip install MetaTrader5") from exc

    if not mt5.initialize(path=args.terminal_path):
        error = mt5.last_error()
        raise RuntimeError(f"MT5 initialize failed: {error}")

    try:
        if not mt5.symbol_select(args.symbol, True):
            raise RuntimeError(f"symbol_select failed for {args.symbol}. Ensure symbol exists in Market Watch.")

        conn = sqlite3.connect(db_path)
        try:
            create_schema(conn)
            day_ranges = generate_day_ranges(start, end)

            total_inserted = 0
            empty_days: List[str] = []

            for day_start, day_end in day_ranges:
                rates = mt5.copy_rates_range(args.symbol, mt5.TIMEFRAME_M1, day_start, day_end)
                inserted = insert_rates(
                    conn,
                    args.symbol,
                    rates,
                    day_start,
                    day_end,
                    args.source_terminal,
                )
                total_inserted += inserted
                if inserted == 0 and day_start.weekday() < 5:
                    empty_days.append(day_start.strftime("%Y-%m-%d"))

            min_max = conn.execute(
                """
                SELECT MIN(ts_server), MAX(ts_server), COUNT(*)
                FROM bars_m1
                WHERE symbol = ?
                """,
                (args.symbol,),
            ).fetchone()
            min_ts, max_ts, row_count = min_max if min_max else (None, None, 0)

            gaps = detect_gaps(conn, args.symbol)
            gaps_csv = summaries_dir / "data_gaps.csv"
            with gaps_csv.open("w", newline="", encoding="utf-8") as f:
                writer = csv.writer(f)
                writer.writerow(["GapStart", "GapEnd", "MissingMinutes"])
                writer.writerows(gaps)

            trading_days = sum(1 for d in day_ranges if d[0].weekday() < 5)
            missing_ratio = (len(empty_days) / trading_days) if trading_days > 0 else 0.0

            payload: Dict[str, object] = {
                "stage": "pull_mt5_m1_to_sqlite",
                "generated_at": utc_now_iso(),
                "symbol": args.symbol,
                "from_date": args.from_date,
                "to_date": args.to_date,
                "terminal_path": args.terminal_path,
                "db_path": str(db_path),
                "rows_inserted_this_run": total_inserted,
                "rows_total_symbol": int(row_count or 0),
                "min_ts_server": min_ts,
                "max_ts_server": max_ts,
                "empty_days_count": len(empty_days),
                "empty_days_sample": empty_days[:50],
                "trading_days_estimate": trading_days,
                "missing_day_ratio": round(float(missing_ratio), 6),
                "gap_segments": len(gaps),
                "gaps_csv": str(gaps_csv),
                "quality_gate_pass": bool(missing_ratio <= 0.005),
                "quality_gate_threshold": 0.005,
            }

            dump_json(summaries_dir / "ingestion_summary.json", payload)
            (logs_dir / "pull_mt5_m1_to_sqlite.log").write_text(
                "Completed ingestion.\n" + str(payload),
                encoding="utf-8",
            )
            print(f"Ingestion complete. SQLite: {db_path}")
            print(f"Rows total for {args.symbol}: {int(row_count or 0)}")
            print(f"Summary: {summaries_dir / 'ingestion_summary.json'}")
        finally:
            conn.close()
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
