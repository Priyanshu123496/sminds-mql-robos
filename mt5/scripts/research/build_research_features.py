#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sqlite3
from pathlib import Path

import pandas as pd

from common import ensure_dir, utc_now_iso


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build daily regime features from M1 bars in SQLite.")
    parser.add_argument("--run-dir", required=True, help="Run folder under mt5/research_runs/<RUN_ID>.")
    parser.add_argument("--db-path", default="", help="Optional SQLite path. Defaults to <run-dir>/data/xauusd_m1.sqlite")
    parser.add_argument("--symbol", default="XAUUSD")
    parser.add_argument("--from-date", default="2021-01-01")
    parser.add_argument("--to-date", default="2025-12-31")
    return parser.parse_args()


def classify_session(hour: int) -> str:
    if 0 <= hour <= 8:
        return "ASIA"
    if 9 <= hour <= 15:
        return "LONDON"
    if 16 <= hour <= 22:
        return "NEWYORK"
    return "OFFHOURS"


def main() -> None:
    args = parse_args()
    run_dir = Path(args.run_dir)
    summaries_dir = ensure_dir(run_dir / "summaries")
    logs_dir = ensure_dir(run_dir / "logs")
    db_path = Path(args.db_path) if args.db_path else (run_dir / "data" / "xauusd_m1.sqlite")

    if not db_path.exists():
        raise FileNotFoundError(f"SQLite database not found: {db_path}")

    conn = sqlite3.connect(db_path)
    try:
        df = pd.read_sql_query(
            """
            SELECT ts_server, open, high, low, close
            FROM bars_m1
            WHERE symbol = ?
              AND ts_server >= ?
              AND ts_server <= ?
            ORDER BY ts_server
            """,
            conn,
            params=(args.symbol, f"{args.from_date} 00:00:00", f"{args.to_date} 23:59:59"),
        )
        if df.empty:
            raise RuntimeError("No bars found for requested symbol/date range.")

        df["ts_server"] = pd.to_datetime(df["ts_server"], utc=False)
        df["day"] = df["ts_server"].dt.date
        df["hour"] = df["ts_server"].dt.hour
        df["ret"] = df["close"].pct_change().fillna(0.0)
        df["ret_sign_change"] = ((df["ret"] > 0).astype(int).diff().abs() > 0).astype(int)
        df["session"] = df["hour"].map(classify_session)

        daily = (
            df.groupby("day")
            .agg(
                open=("open", "first"),
                high=("high", "max"),
                low=("low", "min"),
                close=("close", "last"),
                ret_std=("ret", "std"),
                sign_changes=("ret_sign_change", "sum"),
                bars=("close", "count"),
            )
            .reset_index()
        )
        daily["ret_std"] = daily["ret_std"].fillna(0.0)
        daily["range_abs"] = daily["high"] - daily["low"]
        daily["range_pct"] = (daily["range_abs"] / daily["close"].replace(0, pd.NA)).fillna(0.0) * 100.0

        daily["prev_close"] = daily["close"].shift(1)
        tr_1 = daily["high"] - daily["low"]
        tr_2 = (daily["high"] - daily["prev_close"]).abs()
        tr_3 = (daily["low"] - daily["prev_close"]).abs()
        daily["tr"] = pd.concat([tr_1, tr_2, tr_3], axis=1).max(axis=1)
        daily["atr14"] = daily["tr"].rolling(14, min_periods=1).mean()

        up_move = daily["high"].diff()
        down_move = -daily["low"].diff()
        plus_dm = up_move.where((up_move > down_move) & (up_move > 0), 0.0)
        minus_dm = down_move.where((down_move > up_move) & (down_move > 0), 0.0)
        atr = daily["atr14"].replace(0, pd.NA)
        plus_di = 100.0 * plus_dm.rolling(14, min_periods=1).sum() / atr
        minus_di = 100.0 * minus_dm.rolling(14, min_periods=1).sum() / atr
        dx = (100.0 * (plus_di - minus_di).abs() / (plus_di + minus_di).replace(0, pd.NA)).fillna(0.0)
        daily["adx14"] = dx.rolling(14, min_periods=1).mean().fillna(0.0)

        daily["ema20"] = daily["close"].ewm(span=20, adjust=False).mean()
        daily["ema50"] = daily["close"].ewm(span=50, adjust=False).mean()
        daily["trend_state"] = "RANGE"
        daily.loc[daily["ema20"] > daily["ema50"], "trend_state"] = "UP"
        daily.loc[daily["ema20"] < daily["ema50"], "trend_state"] = "DOWN"

        daily["whipsaw_score"] = (
            (daily["sign_changes"] / daily["bars"].replace(0, pd.NA)).fillna(0.0) * 10000.0
            + daily["ret_std"] * 100000.0
        )

        session_ranges = (
            df.groupby(["day", "session"])
            .agg(session_high=("high", "max"), session_low=("low", "min"))
            .reset_index()
        )
        session_ranges["session_range"] = session_ranges["session_high"] - session_ranges["session_low"]
        session_pivot = session_ranges.pivot(index="day", columns="session", values="session_range").fillna(0.0)
        session_pivot["session_bucket"] = session_pivot.idxmax(axis=1)
        session_bucket = session_pivot["session_bucket"].reset_index()

        features = daily.merge(session_bucket, on="day", how="left")
        features["session_bucket"] = features["session_bucket"].fillna("OFFHOURS")
        features["symbol"] = args.symbol

        upserts = []
        for _, row in features.iterrows():
            upserts.append(
                (
                    row["symbol"],
                    str(row["day"]),
                    float(row["atr14"]),
                    float(row["adx14"]),
                    float(row["range_pct"]),
                    str(row["session_bucket"]),
                    str(row["trend_state"]),
                    float(row["whipsaw_score"]),
                )
            )

        conn.executemany(
            """
            INSERT INTO feature_regime_daily (
                symbol, day, atr14, adx14, range_pct, session_bucket, trend_state, whipsaw_score
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(symbol, day) DO UPDATE SET
                atr14=excluded.atr14,
                adx14=excluded.adx14,
                range_pct=excluded.range_pct,
                session_bucket=excluded.session_bucket,
                trend_state=excluded.trend_state,
                whipsaw_score=excluded.whipsaw_score
            """,
            upserts,
        )
        conn.commit()

        features_out = summaries_dir / "regime_overview.csv"
        features[
            [
                "symbol",
                "day",
                "atr14",
                "adx14",
                "range_pct",
                "session_bucket",
                "trend_state",
                "whipsaw_score",
            ]
        ].to_csv(features_out, index=False)

        profile_out = summaries_dir / "regime_profile_summary.csv"
        profile = (
            features.groupby("trend_state")
            .agg(
                days=("day", "count"),
                avg_atr14=("atr14", "mean"),
                avg_adx14=("adx14", "mean"),
                avg_range_pct=("range_pct", "mean"),
                avg_whipsaw_score=("whipsaw_score", "mean"),
            )
            .reset_index()
        )
        profile.to_csv(profile_out, index=False)

        (logs_dir / "build_research_features.log").write_text(
            f"generated_at={utc_now_iso()}\nrows={len(features)}\nregime_overview={features_out}\n",
            encoding="utf-8",
        )
        print(f"Feature build complete. Rows: {len(features)}")
        print(f"Daily feature CSV: {features_out}")
        print(f"Profile CSV: {profile_out}")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
