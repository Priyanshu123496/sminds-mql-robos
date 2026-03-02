#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import datetime as dt
from pathlib import Path
from statistics import median
from typing import Dict, List

from common import ensure_dir


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Select final candidate set files and recommendation markdown.")
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--target-quarter-net", type=float, default=25000.0)
    parser.add_argument("--top-n", type=int, default=5)
    parser.add_argument("--strategy-tf", default="M15")
    parser.add_argument("--lot", type=float, default=1.0)
    return parser.parse_args()


def load_csv(path: Path) -> List[Dict[str, str]]:
    if not path.exists():
        return []
    with path.open("r", encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def write_set_file(path: Path, row: Dict[str, str], tf_enum: int, lot: float) -> None:
    content = f"""InpLotSize={lot}
InpFastEmaPeriod={row['fast']}
InpSlowEmaPeriod={row['slow']}
InpFilterEmaPeriod={row['filter_ema']}
InpStrategyTimeframe={tf_enum}
InpTradeMode={0 if row['trade_mode'] == 'BUY_ONLY' else 1}
InpUseAdxFilter={row['use_adx']}
InpAdxPeriod={row['adx_period']}
InpMinAdx={row['min_adx']}
InpUseAtrFilter={row['use_atr']}
InpAtrPeriod={row['atr_period']}
InpMinAtr={row['min_atr']}
InpSessionFilter={row['session_filter']}
InpCooldownBars={row['cooldown_bars']}
InpUseSLTP={row['use_sltp']}
InpSL_ATR_Mult={row['sl_atr']}
InpTP_ATR_Mult={row['tp_atr']}
InpEvaluateOnEveryTick=0
InpStrategyMagic=11001100
"""
    path.write_text(content, encoding="ascii")


def tf_to_enum(tf: str) -> int:
    mapping = {
        "M1": 1,
        "M5": 5,
        "M15": 15,
        "M30": 30,
        "H1": 16385,
        "H4": 16388,
        "D1": 16408,
    }
    if tf not in mapping:
        return 15
    return mapping[tf]


def main() -> None:
    args = parse_args()
    run_dir = Path(args.run_dir)
    summaries = ensure_dir(run_dir / "summaries")
    artifacts = ensure_dir(run_dir / "artifacts")
    sets_dir = ensure_dir(artifacts / "sets")

    scoreboard = load_csv(summaries / "quarterly_scoreboard.csv")
    period_rows = load_csv(summaries / "quarterly_period_metrics.csv")
    if not scoreboard:
        raise RuntimeError("Missing or empty quarterly_scoreboard.csv")

    for row in scoreboard:
        row["stage2_min_net_f"] = float(row.get("stage2_min_net", "0") or 0.0)
        row["stage2_avg_net_f"] = float(row.get("stage2_avg_net", "0") or 0.0)
        row["stage2_median_net_f"] = float(row.get("stage2_median_net", "0") or 0.0)
        row["stage2_avg_pf_f"] = float(row.get("stage2_avg_pf", "0") or 0.0)
        row["accepted_i"] = int(row.get("accepted_strict_all12", "0") or 0)

    accepted = [r for r in scoreboard if r["accepted_i"] == 1]
    if accepted:
        selected = sorted(
            accepted,
            key=lambda r: (r["stage2_min_net_f"], r["stage2_avg_net_f"], r["stage2_avg_pf_f"]),
            reverse=True,
        )[: args.top_n]
    else:
        selected = sorted(
            scoreboard,
            key=lambda r: (r["stage2_min_net_f"], r["stage2_avg_net_f"], r["stage2_avg_pf_f"]),
            reverse=True,
        )[: args.top_n]

    tf_enum = tf_to_enum(args.strategy_tf)
    set_rows = []
    for row in selected:
        cid = row["candidate_id"]
        set_path = sets_dir / f"candidate_{cid}.set"
        write_set_file(set_path, row, tf_enum=tf_enum, lot=args.lot)
        row_copy = dict(row)
        row_copy["set_file"] = str(set_path)
        set_rows.append(row_copy)

    out_csv = summaries / "top_candidates.csv"
    if set_rows:
        with out_csv.open("w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=list(set_rows[0].keys()))
            writer.writeheader()
            writer.writerows(set_rows)

    period_by_candidate: Dict[str, List[float]] = {}
    for p in period_rows:
        if p.get("period_type") not in {"Stage2Quarter", "Stage3Quarter"}:
            continue
        cid = p.get("candidate_id", "")
        if not cid:
            continue
        period_by_candidate.setdefault(cid, []).append(float(p.get("net_profit", "0") or 0.0))

    best = selected[0]
    best_id = best["candidate_id"]
    best_quarters = period_by_candidate.get(best_id, [])
    median_q = median(best_quarters) if best_quarters else 0.0

    recommendation_md = summaries / "final_recommendation.md"
    recommendation_md.write_text(
        "\n".join(
            [
                "# Final Recommendation",
                "",
                f"- Generated: {dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace('+00:00', 'Z')}",
                f"- Strict target: all 12 quarters > {args.target_quarter_net:.2f}",
                f"- Accepted candidates: {len(accepted)}",
                "",
                "## Best Candidate",
                "",
                f"- Candidate ID: `{best_id}`",
                f"- Trade mode: `{best['trade_mode']}`",
                f"- Fast/Slow/Filter EMA: `{best['fast']}/{best['slow']}/{best['filter_ema']}`",
                f"- Stage2 Min Quarter Net: `{best['stage2_min_net_f']:.2f}`",
                f"- Stage2 Avg Quarter Net: `{best['stage2_avg_net_f']:.2f}`",
                f"- Stage2 Median Quarter Net: `{median_q:.2f}`",
                f"- Stage2 Avg PF: `{best['stage2_avg_pf_f']:.4f}`",
                "",
                "## Notes",
                "",
                "- Use generated `.set` files under `artifacts/sets` for reproducible reruns.",
                "- Validate top candidates on broker-specific data before live deployment.",
            ]
        ),
        encoding="utf-8",
    )

    print(f"Top candidates CSV: {out_csv}")
    print(f"Set files folder: {sets_dir}")
    print(f"Recommendation: {recommendation_md}")


if __name__ == "__main__":
    main()
