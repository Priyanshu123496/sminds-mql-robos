#!/usr/bin/env python3
from __future__ import annotations

import calendar
import csv
import dataclasses
import datetime as dt
import json
import re
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple


DEFAULT_TERMINAL_PATH = Path(r"C:\Program Files\MetaTrader 5\terminal64.exe")
DEFAULT_METAEDITOR_PATH = Path(r"C:\Program Files\MetaTrader 5\metaeditor64.exe")
DEFAULT_TERMINAL_DATA_DIR = Path(
    r"C:\Users\nagas\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
)


def utc_now_iso() -> str:
    return dt.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"


def ensure_dir(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    return path


def month_end(day_1: dt.date) -> dt.date:
    return day_1.replace(day=calendar.monthrange(day_1.year, day_1.month)[1])


def month_iter(start_month: str, end_month: str) -> List[dt.date]:
    start = dt.datetime.strptime(start_month, "%Y-%m").date().replace(day=1)
    end = dt.datetime.strptime(end_month, "%Y-%m").date().replace(day=1)
    out: List[dt.date] = []
    cur = start
    while cur <= end:
        out.append(cur)
        year = cur.year + (cur.month // 12)
        month = (cur.month % 12) + 1
        cur = cur.replace(year=year, month=month, day=1)
    return out


def quarter_ranges(start_year: int, end_year: int) -> List[Tuple[str, dt.date, dt.date]]:
    out: List[Tuple[str, dt.date, dt.date]] = []
    for year in range(start_year, end_year + 1):
        out.append((f"{year}Q1", dt.date(year, 1, 1), dt.date(year, 3, 31)))
        out.append((f"{year}Q2", dt.date(year, 4, 1), dt.date(year, 6, 30)))
        out.append((f"{year}Q3", dt.date(year, 7, 1), dt.date(year, 9, 30)))
        out.append((f"{year}Q4", dt.date(year, 10, 1), dt.date(year, 12, 31)))
    return out


def to_mt5_date(d: dt.date) -> str:
    return d.strftime("%Y.%m.%d")


def decode_text(raw: bytes) -> str:
    for enc in ("utf-8", "utf-16", "cp1252", "latin-1"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="ignore")


def parse_float(text: str) -> float:
    cleaned = text.replace("\xa0", " ").strip()
    match = re.search(r"[-+]?\d[\d\s,]*(?:\.\d+)?", cleaned)
    if not match:
        return 0.0
    num = match.group(0).replace(" ", "").replace(",", "")
    try:
        return float(num)
    except ValueError:
        return 0.0


def parse_percent(text: str) -> float:
    match = re.search(r"\(([-+]?\d+(?:\.\d+)?)%\)", text)
    if match:
        return float(match.group(1))
    match = re.search(r"([-+]?\d+(?:\.\d+)?)%", text)
    if match:
        return float(match.group(1))
    return 0.0


def extract_first_metric(text: str, label: str) -> Optional[str]:
    pattern = re.compile(
        rf"{re.escape(label)}\s*</td>\s*<td[^>]*>\s*<b>(.*?)</b>",
        flags=re.IGNORECASE | re.DOTALL,
    )
    m = pattern.search(text)
    if not m:
        return None
    return m.group(1).strip()


def extract_count_and_pct(text: str, label: str) -> Tuple[int, float]:
    raw = extract_first_metric(text, label)
    if not raw:
        return 0, 0.0
    return int(parse_float(raw)), parse_percent(raw)


@dataclasses.dataclass
class ReportMetrics:
    report_file: str
    status: str
    net_profit: float
    gross_profit: float
    gross_loss: float
    total_trades: int
    profit_factor: float
    expected_payoff: float
    max_drawdown_abs: float
    max_drawdown_pct: float
    win_rate_pct: float
    avg_win: float
    avg_loss: float


def parse_mt5_report(path: Path) -> ReportMetrics:
    if not path.exists():
        return ReportMetrics(
            report_file=str(path),
            status="MISSING",
            net_profit=0.0,
            gross_profit=0.0,
            gross_loss=0.0,
            total_trades=0,
            profit_factor=0.0,
            expected_payoff=0.0,
            max_drawdown_abs=0.0,
            max_drawdown_pct=0.0,
            win_rate_pct=0.0,
            avg_win=0.0,
            avg_loss=0.0,
        )

    text = decode_text(path.read_bytes())
    profit_trades, win_rate = extract_count_and_pct(text, "Profit Trades (% of total):")
    _loss_trades, _ = extract_count_and_pct(text, "Loss Trades (% of total):")
    balance_dd_max = extract_first_metric(text, "Balance Drawdown Maximal:") or "0"

    return ReportMetrics(
        report_file=str(path),
        status="OK",
        net_profit=parse_float(extract_first_metric(text, "Total Net Profit:") or "0"),
        gross_profit=parse_float(extract_first_metric(text, "Gross Profit:") or "0"),
        gross_loss=parse_float(extract_first_metric(text, "Gross Loss:") or "0"),
        total_trades=int(parse_float(extract_first_metric(text, "Total Trades:") or "0")),
        profit_factor=parse_float(extract_first_metric(text, "Profit Factor:") or "0"),
        expected_payoff=parse_float(extract_first_metric(text, "Expected Payoff:") or "0"),
        max_drawdown_abs=parse_float(balance_dd_max),
        max_drawdown_pct=parse_percent(balance_dd_max),
        win_rate_pct=win_rate if profit_trades > 0 else 0.0,
        avg_win=parse_float(extract_first_metric(text, "Average profit trade:") or "0"),
        avg_loss=parse_float(extract_first_metric(text, "Average loss trade:") or "0"),
    )


def reason_for_gross_loss(m: ReportMetrics) -> str:
    if m.status != "OK":
        return "ParseError or missing report."

    avg_win = max(m.avg_win, 0.0001)
    avg_loss_abs = abs(m.avg_loss)
    if m.max_drawdown_pct >= 35.0:
        return "High drawdown from prolonged adverse move before EMA recross."
    if m.profit_factor < 1.0 and m.total_trades >= 20:
        return "Whipsaw/chop: frequent entries with weak follow-through."
    if m.total_trades <= 8 and m.net_profit < 0.0:
        return "Low-trade period with trend mismatch."
    if avg_loss_abs > avg_win * 1.35:
        return "Loss-size asymmetry exceeded average winner."
    if m.profit_factor < 1.0:
        return "Sub-1 profit factor period."
    return "Normal crossover pullback losses."


def write_ini_file(
    ini_path: Path,
    expert_name: str,
    symbol: str,
    tester_period: str,
    from_date: dt.date,
    to_date: dt.date,
    report_basename: str,
    deposit: int,
    leverage: str,
    inputs_lines: Sequence[str],
    model: int = 4,
) -> None:
    tester_inputs = "\n".join(inputs_lines)
    content = f"""[Tester]
Expert={expert_name}
Symbol={symbol}
Period={tester_period}
Model={model}
ExecutionMode=0
Optimization=0
OptimizationCriterion=0
FromDate={to_mt5_date(from_date)}
ToDate={to_mt5_date(to_date)}
ForwardMode=0
Deposit={deposit}
Currency=USD
Leverage={leverage}
ProfitInPips=0
Report={report_basename}
ReplaceReport=1
ShutdownTerminal=1
Visual=0
[TesterInputs]
{tester_inputs}
"""
    ini_path.write_text(content, encoding="ascii")


def stop_terminal_process() -> None:
    subprocess.run(
        ["taskkill", "/IM", "terminal64.exe", "/F"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    time.sleep(1.0)


def run_terminal_config(terminal_path: Path, ini_path: Path, timeout_sec: int = 5400) -> int:
    completed = subprocess.run(
        [str(terminal_path), f"/config:{ini_path}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout_sec,
        check=False,
        text=True,
    )
    return completed.returncode


def wait_for_report(path: Path, min_mtime: float, timeout_sec: int = 1200) -> bool:
    end = time.time() + timeout_sec
    while time.time() <= end:
        if path.exists():
            if path.stat().st_mtime >= min_mtime:
                return True
        time.sleep(1.0)
    return False


def compile_mq5(metaeditor_path: Path, mq5_path: Path, log_path: Path) -> int:
    ensure_dir(log_path.parent)
    proc = subprocess.run(
        [str(metaeditor_path), f"/compile:{mq5_path}", f"/log:{log_path}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        text=True,
    )
    return proc.returncode


def dump_json(path: Path, payload: Dict[str, Any]) -> None:
    ensure_dir(path.parent)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def append_csv(path: Path, rows: Iterable[Dict[str, Any]], fieldnames: Sequence[str]) -> None:
    ensure_dir(path.parent)
    exists = path.exists()
    with path.open("a", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        if not exists:
            writer.writeheader()
        for row in rows:
            writer.writerow(row)


def copy_if_exists(src: Path, dst: Path) -> bool:
    if not src.exists():
        return False
    ensure_dir(dst.parent)
    shutil.copy2(src, dst)
    return True
