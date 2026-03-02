#!/usr/bin/env python3
from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import hashlib
import json
import random
import sqlite3
import statistics
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

from common import (
    DEFAULT_METAEDITOR_PATH,
    DEFAULT_TERMINAL_DATA_DIR,
    DEFAULT_TERMINAL_PATH,
    ReportMetrics,
    append_csv,
    compile_mq5,
    copy_if_exists,
    dump_json,
    ensure_dir,
    parse_mt5_report,
    quarter_ranges,
    reason_for_gross_loss,
    run_terminal_config,
    stop_terminal_process,
    wait_for_report,
    write_ini_file,
)


TIMEFRAME_TO_ENUM = {
    "M1": 1,
    "M2": 2,
    "M3": 3,
    "M4": 4,
    "M5": 5,
    "M6": 6,
    "M10": 10,
    "M12": 12,
    "M15": 15,
    "M20": 20,
    "M30": 30,
    "H1": 16385,
    "H2": 16386,
    "H3": 16387,
    "H4": 16388,
    "H6": 16390,
    "H8": 16392,
    "H12": 16396,
    "D1": 16408,
}


@dataclasses.dataclass(frozen=True)
class Candidate:
    trade_mode: int
    fast: int
    slow: int
    filter_ema: int
    use_adx: int
    adx_period: int
    min_adx: float
    use_atr: int
    atr_period: int
    min_atr: float
    session_filter: int
    cooldown_bars: int
    use_sltp: int
    sl_atr: float
    tp_atr: float
    evaluate_on_every_tick: int

    def candidate_id(self) -> str:
        payload = (
            f"tm{self.trade_mode}_f{self.fast}_s{self.slow}_fl{self.filter_ema}_"
            f"adx{self.use_adx}_{self.adx_period}_{self.min_adx:.2f}_"
            f"atr{self.use_atr}_{self.atr_period}_{self.min_atr:.2f}_"
            f"sess{self.session_filter}_cd{self.cooldown_bars}_"
            f"sltp{self.use_sltp}_{self.sl_atr:.2f}_{self.tp_atr:.2f}_tick{self.evaluate_on_every_tick}"
        )
        digest = hashlib.md5(payload.encode("utf-8")).hexdigest()[:10]
        return f"cand_{digest}"

    def as_dict(self, tf: str, ea_file: str) -> Dict[str, object]:
        return {
            "candidate_id": self.candidate_id(),
            "ea_file": ea_file,
            "trade_mode": "BUY_ONLY" if self.trade_mode == 0 else "BUY_SELL",
            "tf": tf,
            "fast": self.fast,
            "slow": self.slow,
            "filter": self.filter_ema,
            "use_adx": self.use_adx,
            "adx_period": self.adx_period,
            "min_adx": self.min_adx,
            "use_atr": self.use_atr,
            "atr_period": self.atr_period,
            "min_atr": self.min_atr,
            "session_filter": self.session_filter,
            "cooldown_bars": self.cooldown_bars,
            "sl_atr": self.sl_atr,
            "tp_atr": self.tp_atr,
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run staged strategy search for research EA.")
    parser.add_argument("--repo-root", default=r"C:\SMINDS\projects\sminds-mql-robos")
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--symbol", default="XAUUSD")
    parser.add_argument("--strategy-tf", default="M15")
    parser.add_argument("--terminal-path", default=str(DEFAULT_TERMINAL_PATH))
    parser.add_argument("--metaeditor-path", default=str(DEFAULT_METAEDITOR_PATH))
    parser.add_argument("--terminal-data-dir", default=str(DEFAULT_TERMINAL_DATA_DIR))
    parser.add_argument("--deposit", type=int, default=25000)
    parser.add_argument("--leverage", default="1:1000")
    parser.add_argument("--lot", type=float, default=1.0)
    parser.add_argument("--target-quarter-net", type=float, default=25000.0)
    parser.add_argument("--stage1-max-candidates", type=int, default=48)
    parser.add_argument("--stage1-top", type=int, default=8)
    parser.add_argument("--stage3-seeds", type=int, default=3)
    parser.add_argument("--stage3-max-per-seed", type=int, default=6)
    parser.add_argument("--timeout-sec", type=int, default=900)
    return parser.parse_args()


def candidate_inputs(candidate: Candidate, tf_enum: int, lot: float) -> List[str]:
    return [
        f"InpLotSize={lot}||{lot}||0.010000||100.000000||N",
        f"InpFastEmaPeriod={candidate.fast}||{candidate.fast}||1||500||N",
        f"InpSlowEmaPeriod={candidate.slow}||{candidate.slow}||1||500||N",
        f"InpFilterEmaPeriod={candidate.filter_ema}||{candidate.filter_ema}||1||500||N",
        f"InpStrategyTimeframe={tf_enum}||{tf_enum}||1||50000||N",
        f"InpTradeMode={candidate.trade_mode}||{candidate.trade_mode}||0||1||N",
        f"InpUseAdxFilter={candidate.use_adx}||{candidate.use_adx}||0||1||N",
        f"InpAdxPeriod={candidate.adx_period}||{candidate.adx_period}||1||100||N",
        f"InpMinAdx={candidate.min_adx:.4f}||{candidate.min_adx:.4f}||0.1000||100.0000||N",
        f"InpUseAtrFilter={candidate.use_atr}||{candidate.use_atr}||0||1||N",
        f"InpAtrPeriod={candidate.atr_period}||{candidate.atr_period}||1||100||N",
        f"InpMinAtr={candidate.min_atr:.4f}||{candidate.min_atr:.4f}||0.0100||1000.0000||N",
        f"InpSessionFilter={candidate.session_filter}||{candidate.session_filter}||0||4||N",
        f"InpCooldownBars={candidate.cooldown_bars}||{candidate.cooldown_bars}||0||100||N",
        f"InpUseSLTP={candidate.use_sltp}||{candidate.use_sltp}||0||1||N",
        f"InpSL_ATR_Mult={candidate.sl_atr:.4f}||{candidate.sl_atr:.4f}||0.1000||10.0000||N",
        f"InpTP_ATR_Mult={candidate.tp_atr:.4f}||{candidate.tp_atr:.4f}||0.1000||20.0000||N",
        f"InpEvaluateOnEveryTick={candidate.evaluate_on_every_tick}||{candidate.evaluate_on_every_tick}||0||1||N",
        "InpStrategyMagic=11001100||11001100||1||2147483647||N",
    ]


def build_stage1_candidates(max_candidates: int) -> List[Candidate]:
    fast_slow_pairs = [
        (9, 30),
        (12, 50),
        (15, 60),
        (20, 50),
        (20, 75),
        (25, 89),
        (30, 75),
        (30, 100),
        (34, 89),
        (40, 120),
        (50, 75),
        (50, 150),
    ]
    filters = [150, 200, 250]
    trade_modes = [0, 1]
    adx_cfg = [(0, 14, 0.0), (1, 14, 22.0)]
    atr_cfg = [(0, 14, 0.0), (1, 14, 1.0)]
    sessions = [0, 4]
    cooldowns = [0, 3]
    sltp_cfg = [(0, 2.0, 3.0), (1, 2.0, 3.0)]
    eval_modes = [0]

    full: List[Candidate] = []
    for fast, slow in fast_slow_pairs:
        for fl in filters:
            for tm in trade_modes:
                for use_adx, adx_period, min_adx in adx_cfg:
                    for use_atr, atr_period, min_atr in atr_cfg:
                        for sess in sessions:
                            for cd in cooldowns:
                                for use_sltp, sl_atr, tp_atr in sltp_cfg:
                                    for eval_tick in eval_modes:
                                        if use_sltp == 1 and use_atr == 0:
                                            continue
                                        full.append(
                                            Candidate(
                                                trade_mode=tm,
                                                fast=fast,
                                                slow=slow,
                                                filter_ema=fl,
                                                use_adx=use_adx,
                                                adx_period=adx_period,
                                                min_adx=min_adx,
                                                use_atr=use_atr,
                                                atr_period=atr_period,
                                                min_atr=min_atr,
                                                session_filter=sess,
                                                cooldown_bars=cd,
                                                use_sltp=use_sltp,
                                                sl_atr=sl_atr,
                                                tp_atr=tp_atr,
                                                evaluate_on_every_tick=eval_tick,
                                            )
                                        )
    unique = {c.candidate_id(): c for c in full}
    all_candidates = list(unique.values())
    all_candidates.sort(key=lambda c: c.candidate_id())
    if len(all_candidates) <= max_candidates:
        return all_candidates

    rnd = random.Random(26022501)
    sampled = rnd.sample(all_candidates, max_candidates)
    sampled.sort(key=lambda c: c.candidate_id())
    return sampled


def mutate_candidate(seed: Candidate) -> List[Candidate]:
    deltas = [
        (-2, 0, 0, 0.0, 0.0, 0),
        (2, 0, 0, 0.0, 0.0, 0),
        (0, -10, 0, 0.0, 0.0, 0),
        (0, 10, 0, 0.0, 0.0, 0),
        (0, 0, -25, -2.0, -0.2, 1),
        (0, 0, 25, 2.0, 0.2, 1),
        (0, 0, 0, 2.0, 0.2, 0),
        (0, 0, 0, -2.0, -0.2, 0),
    ]

    out: List[Candidate] = []
    for d_fast, d_slow, d_filter, d_adx, d_atr, d_cd in deltas:
        fast = max(2, seed.fast + d_fast)
        slow = max(fast + 1, seed.slow + d_slow)
        fl = max(20, seed.filter_ema + d_filter)
        min_adx = max(0.0, seed.min_adx + d_adx) if seed.use_adx else 0.0
        min_atr = max(0.0, seed.min_atr + d_atr) if seed.use_atr else 0.0
        cd = max(0, seed.cooldown_bars + d_cd)
        out.append(
            dataclasses.replace(
                seed,
                fast=fast,
                slow=slow,
                filter_ema=fl,
                min_adx=min_adx,
                min_atr=min_atr,
                cooldown_bars=cd,
            )
        )
    unique = {c.candidate_id(): c for c in out}
    return list(unique.values())


def candidate_summary(metrics: List[ReportMetrics]) -> Dict[str, float]:
    net_values = [m.net_profit for m in metrics if m.status == "OK"]
    pf_values = [m.profit_factor for m in metrics if m.status == "OK"]
    dd_values = [m.max_drawdown_pct for m in metrics if m.status == "OK"]
    if not net_values:
        return {
            "min_net": -999999.0,
            "avg_net": -999999.0,
            "median_net": -999999.0,
            "avg_pf": 0.0,
            "max_dd_pct": 0.0,
            "periods_ok": 0,
        }
    return {
        "min_net": min(net_values),
        "avg_net": sum(net_values) / len(net_values),
        "median_net": statistics.median(net_values),
        "avg_pf": sum(pf_values) / len(pf_values) if pf_values else 0.0,
        "max_dd_pct": max(dd_values) if dd_values else 0.0,
        "periods_ok": len(net_values),
    }


def upsert_candidate_row(conn: sqlite3.Connection, tf: str, ea_file: str, c: Candidate, score_stage1: float, score_stage2: float, accepted: int) -> None:
    conn.execute(
        """
        INSERT INTO candidates (
            candidate_id, ea_file, trade_mode, tf, fast, slow, filter, use_adx, adx_period, min_adx,
            use_atr, atr_period, min_atr, session_filter, cooldown_bars, sl_atr, tp_atr,
            score_stage1, score_stage2, accepted
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(candidate_id) DO UPDATE SET
            score_stage1=excluded.score_stage1,
            score_stage2=excluded.score_stage2,
            accepted=excluded.accepted
        """,
        (
            c.candidate_id(),
            ea_file,
            "BUY_ONLY" if c.trade_mode == 0 else "BUY_SELL",
            tf,
            c.fast,
            c.slow,
            c.filter_ema,
            c.use_adx,
            c.adx_period,
            c.min_adx,
            c.use_atr,
            c.atr_period,
            c.min_atr,
            str(c.session_filter),
            c.cooldown_bars,
            c.sl_atr,
            c.tp_atr,
            score_stage1,
            score_stage2,
            accepted,
        ),
    )


def run_single_period(
    candidate: Candidate,
    label: str,
    from_date: dt.date,
    to_date: dt.date,
    *,
    symbol: str,
    tester_tf: str,
    tf_enum: int,
    lot: float,
    deposit: int,
    leverage: str,
    expert_name: str,
    config_dir: Path,
    run_report_dir: Path,
    terminal_data_dir: Path,
    terminal_path: Path,
    timeout_sec: int,
) -> Tuple[Path, ReportMetrics]:
    cid = candidate.candidate_id()
    report_base = f"{cid}_{label}"
    ini_path = config_dir / f"{report_base}.ini"

    write_ini_file(
        ini_path=ini_path,
        expert_name=expert_name,
        symbol=symbol,
        tester_period=tester_tf,
        from_date=from_date,
        to_date=to_date,
        report_basename=report_base,
        deposit=deposit,
        leverage=leverage,
        inputs_lines=candidate_inputs(candidate, tf_enum=tf_enum, lot=lot),
        model=4,
    )

    terminal_report = terminal_data_dir / f"{report_base}.htm"
    run_report = run_report_dir / f"{report_base}.htm"
    if terminal_report.exists():
        terminal_report.unlink()
    if run_report.exists():
        run_report.unlink()

    stop_terminal_process()
    launched_at = dt.datetime.now().timestamp()
    _ = run_terminal_config(terminal_path=terminal_path, ini_path=ini_path, timeout_sec=timeout_sec)
    wait_for_report(terminal_report, launched_at, timeout_sec=timeout_sec)
    copy_if_exists(terminal_report, run_report)

    metrics = parse_mt5_report(run_report)
    return run_report, metrics


def period_rows(
    run_id: str,
    candidate: Candidate,
    period_type: str,
    period_label: str,
    from_date: dt.date,
    to_date: dt.date,
    report_path: Path,
    metrics: ReportMetrics,
) -> Dict[str, object]:
    return {
        "run_id": run_id,
        "candidate_id": candidate.candidate_id(),
        "period_type": period_type,
        "period_label": period_label,
        "from_date": from_date.isoformat(),
        "to_date": to_date.isoformat(),
        "net_profit": round(metrics.net_profit, 2),
        "gross_profit": round(metrics.gross_profit, 2),
        "gross_loss": round(metrics.gross_loss, 2),
        "profit_factor": round(metrics.profit_factor, 4),
        "max_dd_pct": round(metrics.max_drawdown_pct, 4),
        "trades": metrics.total_trades,
        "report_file": str(report_path),
        "status": metrics.status,
        "reason": reason_for_gross_loss(metrics),
    }


def main() -> None:
    args = parse_args()
    if args.strategy_tf not in TIMEFRAME_TO_ENUM:
        raise ValueError(f"Unsupported --strategy-tf: {args.strategy_tf}")

    repo_root = Path(args.repo_root)
    run_dir = Path(args.run_dir)
    run_id = run_dir.name
    config_dir = ensure_dir(run_dir / "config")
    run_report_dir = ensure_dir(run_dir / "reports")
    summaries_dir = ensure_dir(run_dir / "summaries")
    logs_dir = ensure_dir(run_dir / "logs")
    data_dir = ensure_dir(run_dir / "data")

    terminal_data_dir = Path(args.terminal_data_dir)
    terminal_path = Path(args.terminal_path)
    metaeditor_path = Path(args.metaeditor_path)

    expert_mq5 = repo_root / "mt5" / "experts" / "EMA_small_big_EMA200_Buy_TimeFrame_Symbol_Research.mq5"
    expert_ex5 = expert_mq5.with_suffix(".ex5")
    expert_name = expert_ex5.name
    compile_log = logs_dir / "EMA_small_big_EMA200_Buy_TimeFrame_Symbol_Research.compile.log"
    compile_code = compile_mq5(metaeditor_path=metaeditor_path, mq5_path=expert_mq5, log_path=compile_log)
    compile_text = ""
    if compile_log.exists():
        raw = compile_log.read_bytes()
        for enc in ("utf-16", "utf-8", "cp1252", "latin-1"):
            try:
                compile_text = raw.decode(enc)
                break
            except UnicodeDecodeError:
                continue
    compile_ok = expert_ex5.exists() and ("0 errors" in compile_text or compile_code == 0)
    if not compile_ok:
        raise RuntimeError(f"Compile failed. See log: {compile_log}")

    terminal_expert_path = terminal_data_dir / "MQL5" / "Experts" / expert_name
    ensure_dir(terminal_expert_path.parent)
    terminal_expert_path.write_bytes(expert_ex5.read_bytes())

    db_path = data_dir / "xauusd_m1.sqlite"
    if not db_path.exists():
        # DB is created in pull stage; allow continuing without inserts if absent.
        db_path.parent.mkdir(parents=True, exist_ok=True)
        sqlite3.connect(db_path).close()

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        stage1_periods = quarter_ranges(2021, 2022)
        stage2_periods = quarter_ranges(2023, 2025)

        stage1_candidates = build_stage1_candidates(args.stage1_max_candidates)
        stage1_scores: Dict[str, Dict[str, float]] = {}
        stage2_scores: Dict[str, Dict[str, float]] = {}
        period_records: List[Dict[str, object]] = []

        for c in stage1_candidates:
            cid = c.candidate_id()
            metrics: List[ReportMetrics] = []
            for label, from_d, to_d in stage1_periods:
                report_path, report_metrics = run_single_period(
                    c,
                    f"stage1_{label}",
                    from_d,
                    to_d,
                    symbol=args.symbol,
                    tester_tf=args.strategy_tf,
                    tf_enum=TIMEFRAME_TO_ENUM[args.strategy_tf],
                    lot=args.lot,
                    deposit=args.deposit,
                    leverage=args.leverage,
                    expert_name=expert_name,
                    config_dir=config_dir,
                    run_report_dir=run_report_dir,
                    terminal_data_dir=terminal_data_dir,
                    terminal_path=terminal_path,
                    timeout_sec=args.timeout_sec,
                )
                metrics.append(report_metrics)
                period_records.append(
                    period_rows(
                        run_id,
                        c,
                        "Stage1Quarter",
                        label,
                        from_d,
                        to_d,
                        report_path,
                        report_metrics,
                    )
                )

            summary = candidate_summary(metrics)
            stage1_scores[cid] = summary

        ranked_stage1 = sorted(
            stage1_candidates,
            key=lambda c: (
                stage1_scores[c.candidate_id()]["min_net"],
                stage1_scores[c.candidate_id()]["avg_net"],
                stage1_scores[c.candidate_id()]["avg_pf"],
            ),
            reverse=True,
        )
        stage2_input = ranked_stage1[: args.stage1_top]

        for c in stage2_input:
            cid = c.candidate_id()
            metrics: List[ReportMetrics] = []
            for label, from_d, to_d in stage2_periods:
                report_path, report_metrics = run_single_period(
                    c,
                    f"stage2_{label}",
                    from_d,
                    to_d,
                    symbol=args.symbol,
                    tester_tf=args.strategy_tf,
                    tf_enum=TIMEFRAME_TO_ENUM[args.strategy_tf],
                    lot=args.lot,
                    deposit=args.deposit,
                    leverage=args.leverage,
                    expert_name=expert_name,
                    config_dir=config_dir,
                    run_report_dir=run_report_dir,
                    terminal_data_dir=terminal_data_dir,
                    terminal_path=terminal_path,
                    timeout_sec=args.timeout_sec,
                )
                metrics.append(report_metrics)
                period_records.append(
                    period_rows(
                        run_id,
                        c,
                        "Stage2Quarter",
                        label,
                        from_d,
                        to_d,
                        report_path,
                        report_metrics,
                    )
                )
            stage2_scores[cid] = candidate_summary(metrics)

        accepted_stage2 = [
            c
            for c in stage2_input
            if stage2_scores.get(c.candidate_id(), {}).get("min_net", -999999.0) > args.target_quarter_net
        ]
        seed_pool = accepted_stage2 if accepted_stage2 else sorted(
            stage2_input,
            key=lambda c: stage2_scores.get(c.candidate_id(), {}).get("min_net", -999999.0),
            reverse=True,
        )
        seeds = seed_pool[: args.stage3_seeds]

        stage3_candidates: Dict[str, Candidate] = {}
        for seed in seeds:
            mutations = mutate_candidate(seed)
            for m in mutations[: args.stage3_max_per_seed]:
                stage3_candidates[m.candidate_id()] = m

        for c in stage3_candidates.values():
            cid = c.candidate_id()
            if cid in stage2_scores:
                continue
            metrics: List[ReportMetrics] = []
            for label, from_d, to_d in stage2_periods:
                report_path, report_metrics = run_single_period(
                    c,
                    f"stage3_{label}",
                    from_d,
                    to_d,
                    symbol=args.symbol,
                    tester_tf=args.strategy_tf,
                    tf_enum=TIMEFRAME_TO_ENUM[args.strategy_tf],
                    lot=args.lot,
                    deposit=args.deposit,
                    leverage=args.leverage,
                    expert_name=expert_name,
                    config_dir=config_dir,
                    run_report_dir=run_report_dir,
                    terminal_data_dir=terminal_data_dir,
                    terminal_path=terminal_path,
                    timeout_sec=args.timeout_sec,
                )
                metrics.append(report_metrics)
                period_records.append(
                    period_rows(
                        run_id,
                        c,
                        "Stage3Quarter",
                        label,
                        from_d,
                        to_d,
                        report_path,
                        report_metrics,
                    )
                )
            stage2_scores[cid] = candidate_summary(metrics)

        all_candidates: Dict[str, Candidate] = {c.candidate_id(): c for c in stage1_candidates}
        for c in stage2_input:
            all_candidates[c.candidate_id()] = c
        for c in stage3_candidates.values():
            all_candidates[c.candidate_id()] = c

        scoreboard_rows: List[Dict[str, object]] = []
        for cid, c in all_candidates.items():
            s1 = stage1_scores.get(cid, {})
            s2 = stage2_scores.get(cid, {})
            accepted = int(s2.get("min_net", -999999.0) > args.target_quarter_net)
            row = {
                "run_id": run_id,
                "candidate_id": cid,
                "trade_mode": "BUY_ONLY" if c.trade_mode == 0 else "BUY_SELL",
                "tf": args.strategy_tf,
                "fast": c.fast,
                "slow": c.slow,
                "filter_ema": c.filter_ema,
                "use_adx": c.use_adx,
                "adx_period": c.adx_period,
                "min_adx": c.min_adx,
                "use_atr": c.use_atr,
                "atr_period": c.atr_period,
                "min_atr": c.min_atr,
                "session_filter": c.session_filter,
                "cooldown_bars": c.cooldown_bars,
                "use_sltp": c.use_sltp,
                "sl_atr": c.sl_atr,
                "tp_atr": c.tp_atr,
                "stage1_min_net": round(float(s1.get("min_net", 0.0)), 2),
                "stage1_avg_net": round(float(s1.get("avg_net", 0.0)), 2),
                "stage1_avg_pf": round(float(s1.get("avg_pf", 0.0)), 4),
                "stage2_min_net": round(float(s2.get("min_net", 0.0)), 2),
                "stage2_avg_net": round(float(s2.get("avg_net", 0.0)), 2),
                "stage2_median_net": round(float(s2.get("median_net", 0.0)), 2),
                "stage2_avg_pf": round(float(s2.get("avg_pf", 0.0)), 4),
                "stage2_max_dd_pct": round(float(s2.get("max_dd_pct", 0.0)), 4),
                "accepted_strict_all12": accepted,
                "target_quarter_net": args.target_quarter_net,
            }
            scoreboard_rows.append(row)
            upsert_candidate_row(
                conn=conn,
                tf=args.strategy_tf,
                ea_file=expert_name,
                c=c,
                score_stage1=float(s1.get("min_net", -999999.0)),
                score_stage2=float(s2.get("min_net", -999999.0)),
                accepted=accepted,
            )

        conn.executemany(
            """
            INSERT INTO backtest_runs (
                run_id, candidate_id, period_type, period_label, from_date, to_date, net_profit, gross_profit,
                gross_loss, profit_factor, max_dd_pct, trades, report_file, status
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                (
                    str(r["run_id"]),
                    str(r["candidate_id"]),
                    str(r["period_type"]),
                    str(r["period_label"]),
                    str(r["from_date"]),
                    str(r["to_date"]),
                    float(r["net_profit"]),
                    float(r["gross_profit"]),
                    float(r["gross_loss"]),
                    float(r["profit_factor"]),
                    float(r["max_dd_pct"]),
                    int(r["trades"]),
                    str(r["report_file"]),
                    str(r["status"]),
                )
                for r in period_records
            ],
        )
        conn.commit()

        scoreboard_rows.sort(key=lambda r: (float(r["stage2_min_net"]), float(r["stage2_avg_net"])), reverse=True)
        scoreboard_csv = summaries_dir / "quarterly_scoreboard.csv"
        append_csv(
            scoreboard_csv,
            scoreboard_rows,
            fieldnames=list(scoreboard_rows[0].keys()) if scoreboard_rows else [],
        )

        period_csv = summaries_dir / "quarterly_period_metrics.csv"
        append_csv(
            period_csv,
            period_records,
            fieldnames=[
                "run_id",
                "candidate_id",
                "period_type",
                "period_label",
                "from_date",
                "to_date",
                "net_profit",
                "gross_profit",
                "gross_loss",
                "profit_factor",
                "max_dd_pct",
                "trades",
                "report_file",
                "status",
                "reason",
            ],
        )

        accepted_rows = [r for r in scoreboard_rows if int(r["accepted_strict_all12"]) == 1]
        top_csv = summaries_dir / "top_candidates.csv"
        top_payload = accepted_rows if accepted_rows else scoreboard_rows[:10]
        if top_payload:
            append_csv(top_csv, top_payload, fieldnames=list(top_payload[0].keys()))

        manifest = {
            "run_id": run_id,
            "generated_at": dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            "expert_mq5": str(expert_mq5),
            "expert_ex5": str(expert_ex5),
            "terminal_expert_path": str(terminal_expert_path),
            "symbol": args.symbol,
            "strategy_tf": args.strategy_tf,
            "deposit": args.deposit,
            "leverage": args.leverage,
            "lot": args.lot,
            "target_quarter_net": args.target_quarter_net,
            "stage1_candidates": len(stage1_candidates),
            "stage2_candidates": len(stage2_input),
            "stage3_candidates": len(stage3_candidates),
            "accepted_count": len(accepted_rows),
            "scoreboard_csv": str(scoreboard_csv),
            "period_csv": str(period_csv),
            "top_candidates_csv": str(top_csv),
            "compile_log": str(compile_log),
        }
        dump_json(summaries_dir / "run_manifest.json", manifest)
        (logs_dir / "run_strategy_search.log").write_text(json.dumps(manifest, indent=2), encoding="utf-8")

        print(f"Scoreboard: {scoreboard_csv}")
        print(f"Detailed periods: {period_csv}")
        print(f"Top candidates: {top_csv}")
        print(f"Manifest: {summaries_dir / 'run_manifest.json'}")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
