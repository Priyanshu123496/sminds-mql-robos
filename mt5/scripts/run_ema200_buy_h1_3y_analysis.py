#!/usr/bin/env python3
import argparse
import calendar
import csv
import dataclasses
import datetime as dt
import re
import shutil
import subprocess
import time
from pathlib import Path
from typing import Dict, List, Optional


def month_iter(start_month: str, end_month: str) -> List[dt.date]:
    start = dt.datetime.strptime(start_month, "%Y-%m").date().replace(day=1)
    end = dt.datetime.strptime(end_month, "%Y-%m").date().replace(day=1)
    months: List[dt.date] = []
    cur = start
    while cur <= end:
        months.append(cur)
        year = cur.year + (cur.month // 12)
        month = (cur.month % 12) + 1
        cur = cur.replace(year=year, month=month, day=1)
    return months


def month_end(d: dt.date) -> dt.date:
    return d.replace(day=calendar.monthrange(d.year, d.month)[1])


def to_mt5_date(d: dt.date) -> str:
    return d.strftime("%Y.%m.%d")


def parse_float(text: str) -> float:
    cleaned = text.replace("\xa0", " ").strip()
    m = re.search(r"[-+]?\d[\d\s,]*(?:\.\d+)?", cleaned)
    if not m:
        return 0.0
    num = m.group(0).replace(" ", "").replace(",", "")
    try:
        return float(num)
    except ValueError:
        return 0.0


def parse_percent(text: str) -> float:
    m = re.search(r"\(([-+]?\d+(?:\.\d+)?)%\)", text)
    if m:
        return float(m.group(1))
    m = re.search(r"([-+]?\d+(?:\.\d+)?)%", text)
    if m:
        return float(m.group(1))
    return 0.0


def extract_first(text: str, label: str) -> Optional[str]:
    pattern = re.compile(
        rf"{re.escape(label)}\s*</td>\s*<td[^>]*>\s*<b>(.*?)</b>",
        flags=re.IGNORECASE | re.DOTALL,
    )
    m = pattern.search(text)
    if not m:
        return None
    return m.group(1).strip()


def extract_count_and_pct(text: str, label: str) -> (int, float):
    val = extract_first(text, label)
    if not val:
        return 0, 0.0
    count = int(parse_float(val))
    pct = parse_percent(val)
    return count, pct


def load_report_text(report_path: Path) -> str:
    raw = report_path.read_bytes()
    for enc in ("utf-8", "utf-16", "cp1252", "latin-1"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="ignore")


@dataclasses.dataclass
class MonthlyMetrics:
    period_type: str
    period: str
    from_date: str
    to_date: str
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
    report_file: str
    reason_for_gross_loss: str
    profit_trades: int = 0
    loss_trades: int = 0
    parse_error: bool = False


def reason_for_loss(m: MonthlyMetrics) -> str:
    if m.parse_error:
        return "ParseError: report missing or unreadable."

    avg_win = max(m.avg_win, 0.0001)
    avg_loss_abs = abs(m.avg_loss)

    if m.max_drawdown_pct >= 35.0:
        return "High drawdown from prolonged adverse move before EMA recross."
    if m.profit_factor < 1.0 and m.total_trades >= 20:
        return "Whipsaw/chop: frequent EMA cross entries with low payoff quality."
    if m.total_trades <= 8 and m.net_profit < 0:
        return "Low-trade month and trend mismatch reduced edge."
    if avg_loss_abs > avg_win * 1.35:
        return "Loss-size asymmetry: adverse move before crossover exit exceeded average winners."
    if m.profit_factor < 1.0:
        return "Sub-1.0 profit factor month: crossover entries lacked trend follow-through."
    return "Normal crossover pullback losses within trend-following behavior."


def parse_report(report_path: Path, period: str, from_date: dt.date, to_date: dt.date) -> MonthlyMetrics:
    base = MonthlyMetrics(
        period_type="Monthly",
        period=period,
        from_date=from_date.isoformat(),
        to_date=to_date.isoformat(),
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
        report_file=str(report_path),
        reason_for_gross_loss="",
        parse_error=False,
    )

    if not report_path.exists():
        base.parse_error = True
        base.reason_for_gross_loss = reason_for_loss(base)
        return base

    text = load_report_text(report_path)

    total_net_profit = extract_first(text, "Total Net Profit:")
    gross_profit = extract_first(text, "Gross Profit:")
    gross_loss = extract_first(text, "Gross Loss:")
    total_trades = extract_first(text, "Total Trades:")
    profit_factor = extract_first(text, "Profit Factor:")
    expected_payoff = extract_first(text, "Expected Payoff:")
    balance_drawdown_max = extract_first(text, "Balance Drawdown Maximal:")
    avg_profit_trade = extract_first(text, "Average profit trade:")
    avg_loss_trade = extract_first(text, "Average loss trade:")

    base.net_profit = parse_float(total_net_profit or "0")
    base.gross_profit = parse_float(gross_profit or "0")
    base.gross_loss = parse_float(gross_loss or "0")
    base.total_trades = int(parse_float(total_trades or "0"))
    base.profit_factor = parse_float(profit_factor or "0")
    base.expected_payoff = parse_float(expected_payoff or "0")
    base.max_drawdown_abs = parse_float(balance_drawdown_max or "0")
    base.max_drawdown_pct = parse_percent(balance_drawdown_max or "")
    base.avg_win = parse_float(avg_profit_trade or "0")
    base.avg_loss = parse_float(avg_loss_trade or "0")

    profit_trades, win_rate = extract_count_and_pct(text, "Profit Trades (% of total):")
    loss_trades, _ = extract_count_and_pct(text, "Loss Trades (% of total):")
    base.profit_trades = profit_trades
    base.loss_trades = loss_trades
    base.win_rate_pct = win_rate

    base.reason_for_gross_loss = reason_for_loss(base)
    return base


def write_ini(
    ini_path: Path,
    report_name: str,
    from_date: dt.date,
    to_date: dt.date,
    deposit: int,
    leverage: str,
    profit_in_pips: int,
):
    content = f"""[Tester]
Expert=EMA_small_big_EMA200_Buy_TimeFrame_Symbol.ex5
Symbol=XAUUSD
Period=H1
Model=4
ExecutionMode=0
Optimization=0
OptimizationCriterion=0
FromDate={to_mt5_date(from_date)}
ToDate={to_mt5_date(to_date)}
ForwardMode=0
Deposit={deposit}
Currency=USD
Leverage={leverage}
ProfitInPips={profit_in_pips}
Report={report_name}
ReplaceReport=1
ShutdownTerminal=1
Visual=0
[TesterInputs]
InpLotSize=1.0||1.0||0.100000||100.000000||N
InpFastEmaPeriod=50||50||1||500||N
InpSlowEmaPeriod=75||75||1||500||N
InpStrategyTimeframe=16385||16385||1||43200||N
"""
    ini_path.write_text(content, encoding="ascii")


def run_tester(terminal_path: Path, ini_path: Path, timeout_sec: int = 3600) -> int:
    proc = subprocess.run(
        [str(terminal_path), "/portable", f"/config:{ini_path}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout_sec,
    )
    return proc.returncode


def ensure_terminal_stopped() -> None:
    # MT5 accepts one GUI instance per data directory. A running instance can ignore /config automation.
    subprocess.run(
        ["taskkill", "/IM", "terminal64.exe", "/F"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    time.sleep(1.0)


def wait_for_report(report_path: Path, min_mtime: float, timeout_sec: int = 900) -> bool:
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        if report_path.exists():
            mtime = report_path.stat().st_mtime
            if mtime >= min_mtime:
                return True
        time.sleep(1.0)
    return False


def wait_for_terminal_exit(timeout_sec: int = 300) -> bool:
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        proc = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq terminal64.exe"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        if "terminal64.exe" not in proc.stdout.lower():
            return True
        time.sleep(1.0)
    return False


def yearly_rollup(rows: List[MonthlyMetrics], year: int) -> MonthlyMetrics:
    year_rows = [r for r in rows if r.period.startswith(f"{year}-")]
    if not year_rows:
        return MonthlyMetrics(
            period_type="Yearly",
            period=str(year),
            from_date=f"{year}-01-01",
            to_date=f"{year}-12-31",
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
            report_file=f"ROLLUP:{year}",
            reason_for_gross_loss="No monthly rows available.",
            parse_error=True,
        )

    net = sum(r.net_profit for r in year_rows)
    gp = sum(r.gross_profit for r in year_rows)
    gl = sum(r.gross_loss for r in year_rows)
    trades = sum(r.total_trades for r in year_rows)
    p_trades = sum(r.profit_trades for r in year_rows)
    l_trades = sum(r.loss_trades for r in year_rows)

    pf = gp / abs(gl) if gl != 0 else 0.0
    expected = net / trades if trades > 0 else 0.0
    max_dd_abs = max((r.max_drawdown_abs for r in year_rows), default=0.0)
    max_dd_pct = max((r.max_drawdown_pct for r in year_rows), default=0.0)

    win_rate = (p_trades / trades * 100.0) if trades > 0 else 0.0

    avg_win = (
        sum((r.avg_win * r.profit_trades) for r in year_rows) / p_trades if p_trades > 0 else 0.0
    )
    avg_loss = (
        sum((r.avg_loss * r.loss_trades) for r in year_rows) / l_trades if l_trades > 0 else 0.0
    )

    y = MonthlyMetrics(
        period_type="Yearly",
        period=str(year),
        from_date=f"{year}-01-01",
        to_date=f"{year}-12-31",
        net_profit=net,
        gross_profit=gp,
        gross_loss=gl,
        total_trades=trades,
        profit_factor=pf,
        expected_payoff=expected,
        max_drawdown_abs=max_dd_abs,
        max_drawdown_pct=max_dd_pct,
        win_rate_pct=win_rate,
        avg_win=avg_win,
        avg_loss=avg_loss,
        report_file=f"ROLLUP:{year}",
        reason_for_gross_loss="",
        parse_error=False,
        profit_trades=p_trades,
        loss_trades=l_trades,
    )
    y.reason_for_gross_loss = reason_for_loss(y)
    return y


def fmt_num(v: float) -> str:
    return f"{v:.2f}"


def write_csv(output_csv: Path, rows: List[MonthlyMetrics]):
    output_csv.parent.mkdir(parents=True, exist_ok=True)
    with output_csv.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "PeriodType",
                "Period",
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
                "ReasonForGrossLoss",
            ],
        )
        writer.writeheader()
        for r in rows:
            writer.writerow(
                {
                    "PeriodType": r.period_type,
                    "Period": r.period,
                    "FromDate": r.from_date,
                    "ToDate": r.to_date,
                    "NetProfit": fmt_num(r.net_profit),
                    "GrossProfit": fmt_num(r.gross_profit),
                    "GrossLoss": fmt_num(r.gross_loss),
                    "TotalTrades": r.total_trades,
                    "ProfitFactor": fmt_num(r.profit_factor),
                    "ExpectedPayoff": fmt_num(r.expected_payoff),
                    "MaxDrawdownAbs": fmt_num(r.max_drawdown_abs),
                    "MaxDrawdownPct": fmt_num(r.max_drawdown_pct),
                    "WinRatePct": fmt_num(r.win_rate_pct),
                    "AvgWin": fmt_num(r.avg_win),
                    "AvgLoss": fmt_num(r.avg_loss),
                    "ReportFile": r.report_file,
                    "ReasonForGrossLoss": r.reason_for_gross_loss,
                }
            )


def main() -> int:
    parser = argparse.ArgumentParser(description="Run 3-year monthly MT5 backtests and summarize metrics.")
    parser.add_argument("--repo-root", default=r"C:\SMINDS\projects\sminds-mql-robos")
    parser.add_argument("--terminal-path", default=r"C:\Program Files\MetaTrader 5\terminal64.exe")
    parser.add_argument(
        "--terminal-data-dir",
        default=r"C:\Users\nagas\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075",
    )
    parser.add_argument("--from-month", default="2023-01")
    parser.add_argument("--to-month", default="2025-12")
    parser.add_argument("--deposit", type=int, default=25000)
    parser.add_argument("--leverage", default="1:1000")
    parser.add_argument("--profit-in-pips", type=int, default=0)
    parser.add_argument("--skip-run", action="store_true", help="Only parse existing reports and build CSV.")
    args = parser.parse_args()

    repo_root = Path(args.repo_root)
    terminal_path = Path(args.terminal_path)
    terminal_data_dir = Path(args.terminal_data_dir)
    config_dir = repo_root / "mt5" / "config"
    report_dir = repo_root / "mt5" / "reports"

    output_csv = report_dir / "EMA_small_big_EMA200_Buy_TimeFrame_Symbol_XAUUSD_H1_EMA50_75_2023_2025_monthly_yearly.csv"

    config_dir.mkdir(parents=True, exist_ok=True)
    report_dir.mkdir(parents=True, exist_ok=True)

    month_starts = month_iter(args.from_month, args.to_month)
    monthly_rows: List[MonthlyMetrics] = []

    if not args.skip_run:
        ensure_terminal_stopped()

    for ms in month_starts:
        me = month_end(ms)
        period = ms.strftime("%Y-%m")
        yyyymm = ms.strftime("%Y%m")
        report_name = f"ema50_75_200_buy_xauusd_h1_{yyyymm}"
        ini_name = f"EMA_small_big_EMA200_Buy_TimeFrame_Symbol_XAUUSD_H1_EMA50_75_{yyyymm}.ini"
        ini_path = config_dir / ini_name
        report_path = report_dir / f"{report_name}.htm"
        terminal_report_path = terminal_data_dir / f"{report_name}.htm"

        write_ini(
            ini_path=ini_path,
            report_name=report_name,
            from_date=ms,
            to_date=me,
            deposit=args.deposit,
            leverage=args.leverage,
            profit_in_pips=args.profit_in_pips,
        )

        if not args.skip_run:
            if terminal_report_path.exists():
                terminal_report_path.unlink()
            if report_path.exists():
                report_path.unlink()

            launched_at = time.time()
            code = run_tester(terminal_path=terminal_path, ini_path=ini_path)
            if code not in (0, 1):
                print(f"WARN: tester returned code {code} for {period}")
            if not wait_for_report(terminal_report_path, launched_at):
                print(f"WARN: report not generated in terminal data dir for {period}")
            elif terminal_report_path.exists():
                shutil.copy2(terminal_report_path, report_path)

            if not wait_for_terminal_exit():
                print(f"WARN: terminal process still running after timeout for {period}")

        row = parse_report(report_path=report_path, period=period, from_date=ms, to_date=me)
        monthly_rows.append(row)
        print(
            f"{period}: Net={row.net_profit:.2f}, GP={row.gross_profit:.2f}, GL={row.gross_loss:.2f}, "
            f"Trades={row.total_trades}, PF={row.profit_factor:.2f}, DD%={row.max_drawdown_pct:.2f}"
        )

    yearly_rows = [yearly_rollup(monthly_rows, y) for y in (2023, 2024, 2025)]
    all_rows = monthly_rows + yearly_rows

    write_csv(output_csv, all_rows)

    parse_errors = sum(1 for r in monthly_rows if r.parse_error)
    print(f"CSV written: {output_csv}")
    print(f"Monthly rows: {len(monthly_rows)}, Yearly rows: {len(yearly_rows)}, Total: {len(all_rows)}")
    print(f"Parse errors: {parse_errors}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
