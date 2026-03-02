#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime as dt
import json
import subprocess
import sys
from pathlib import Path
from typing import Dict

from common import DEFAULT_METAEDITOR_PATH, DEFAULT_TERMINAL_DATA_DIR, DEFAULT_TERMINAL_PATH, dump_json, ensure_dir


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run full MT5 research pipeline.")
    parser.add_argument("--repo-root", default=r"C:\SMINDS\projects\sminds-mql-robos")
    parser.add_argument("--symbol", default="XAUUSD")
    parser.add_argument("--from-date", default="2021-01-01")
    parser.add_argument("--to-date", default="2025-12-31")
    parser.add_argument("--strategy-tf", default="M15")
    parser.add_argument("--deposit", type=int, default=25000)
    parser.add_argument("--leverage", default="1:1000")
    parser.add_argument("--lot", type=float, default=1.0)
    parser.add_argument("--target-quarter-net", type=float, default=25000.0)
    parser.add_argument("--stage1-max-candidates", type=int, default=48)
    parser.add_argument("--stage1-top", type=int, default=8)
    parser.add_argument("--stage3-seeds", type=int, default=3)
    parser.add_argument("--stage3-max-per-seed", type=int, default=6)
    parser.add_argument("--timeout-sec", type=int, default=900)
    parser.add_argument("--terminal-path", default=str(DEFAULT_TERMINAL_PATH))
    parser.add_argument("--metaeditor-path", default=str(DEFAULT_METAEDITOR_PATH))
    parser.add_argument("--terminal-data-dir", default=str(DEFAULT_TERMINAL_DATA_DIR))
    return parser.parse_args()


def run_cmd(cmd: list[str], cwd: Path) -> None:
    proc = subprocess.run(cmd, cwd=str(cwd), check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"Command failed ({proc.returncode}): {' '.join(cmd)}")


def load_json(path: Path) -> Dict[str, object]:
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> None:
    args = parse_args()
    repo_root = Path(args.repo_root)
    research_root = ensure_dir(repo_root / "mt5" / "research_runs")
    run_id = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir = ensure_dir(research_root / run_id)
    for d in ["data", "data_raw", "config", "reports", "reports_parsed", "artifacts", "summaries", "logs"]:
        ensure_dir(run_dir / d)

    script_dir = repo_root / "mt5" / "scripts" / "research"
    py = sys.executable

    pull_cmd = [
        py,
        str(script_dir / "pull_mt5_m1_to_sqlite.py"),
        "--run-dir",
        str(run_dir),
        "--symbol",
        args.symbol,
        "--from-date",
        args.from_date,
        "--to-date",
        args.to_date,
        "--terminal-path",
        args.terminal_path,
    ]
    run_cmd(pull_cmd, cwd=repo_root)

    feature_cmd = [
        py,
        str(script_dir / "build_research_features.py"),
        "--run-dir",
        str(run_dir),
        "--symbol",
        args.symbol,
        "--from-date",
        args.from_date,
        "--to-date",
        args.to_date,
    ]
    run_cmd(feature_cmd, cwd=repo_root)

    search_cmd = [
        py,
        str(script_dir / "run_strategy_search.py"),
        "--repo-root",
        str(repo_root),
        "--run-dir",
        str(run_dir),
        "--symbol",
        args.symbol,
        "--strategy-tf",
        args.strategy_tf,
        "--deposit",
        str(args.deposit),
        "--leverage",
        args.leverage,
        "--lot",
        str(args.lot),
        "--target-quarter-net",
        str(args.target_quarter_net),
        "--stage1-max-candidates",
        str(args.stage1_max_candidates),
        "--stage1-top",
        str(args.stage1_top),
        "--stage3-seeds",
        str(args.stage3_seeds),
        "--stage3-max-per-seed",
        str(args.stage3_max_per_seed),
        "--timeout-sec",
        str(args.timeout_sec),
        "--terminal-path",
        args.terminal_path,
        "--metaeditor-path",
        args.metaeditor_path,
        "--terminal-data-dir",
        args.terminal_data_dir,
    ]
    run_cmd(search_cmd, cwd=repo_root)

    select_cmd = [
        py,
        str(script_dir / "select_final_candidates.py"),
        "--run-dir",
        str(run_dir),
        "--target-quarter-net",
        str(args.target_quarter_net),
        "--strategy-tf",
        args.strategy_tf,
        "--lot",
        str(args.lot),
    ]
    run_cmd(select_cmd, cwd=repo_root)

    ingestion = load_json(run_dir / "summaries" / "ingestion_summary.json")
    search = load_json(run_dir / "summaries" / "run_manifest.json")
    final_manifest = {
        "run_id": run_id,
        "run_dir": str(run_dir),
        "symbol": args.symbol,
        "date_range": {"from": args.from_date, "to": args.to_date},
        "strategy_tf": args.strategy_tf,
        "deposit": args.deposit,
        "leverage": args.leverage,
        "lot": args.lot,
        "target_quarter_net": args.target_quarter_net,
        "ingestion": ingestion,
        "search": search,
    }
    dump_json(run_dir / "summaries" / "run_manifest.json", final_manifest)
    print(f"Pipeline complete. Run directory: {run_dir}")


if __name__ == "__main__":
    main()
