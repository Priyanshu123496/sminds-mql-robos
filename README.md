# sminds-mql-robos

## Files
- `Experts/XAUUSD_RobustBreakout.mq5`: MT5 EA implementation.
- `config/XAUUSD_RobustBreakout.opt.set`: optimization profile and ranges.
- `tools/run_mt5_backtest.ps1`: deterministic MT5 Strategy Tester CLI launcher.
- `tools/analyze_trade_log.py`: parses EA CSV logs (`ENTRY`, `DEAL_OUT`, `GATE_STATS`, `REGIME_STATS`).
- `tools/aggregate_splits.py`: merges split runs and evaluates PF/DD acceptance gates.
- `tools/wfo_summary.py`: XML-only walk-forward summary utility.
- `docs/OPTIMIZATION_PROTOCOL.md`: staged optimization and validation process.

## Default Regime-Resilient Mode
- `EntryTriggerMode = ENTRY_TRIGGER_BAR_CLOSE` (effective when `UseBarCloseConfirmation=true`).
- `RequireCrossingSignal=true`
- `CooldownBarsAfterLoss=3`
- `MaxAtrToPricePct=0.30`
- `UseTrendSlopeFilter=true`
- `UseVolatilityPercentileFilter=true`
- `UseReentryPullbackLock=true`
- `MinBreakoutExcessAtr=0.10`

## MT5 CLI Backtest Run
Example:

```powershell
powershell -File tools/run_mt5_backtest.ps1 `
  -SetFile config/XAUUSD_RobustBreakout.opt.set `
  -FromDate 2025.08.01 `
  -ToDate 2026.02.22 `
  -RunLabel baseline_run_001 `
  -SplitTag combined `
  -CloseRunningTerminal
```

Run artifacts are written under `outputs/mt5_runs/<RunLabel>/`:
- `tester.ini`
- `run_metadata.json`
- `mt5_report*.htm/html` (MT5 native report)
- `mt5_report_fallback.xml` (generated from `trade_log.csv` when MT5 XML is unavailable)
- `trade_log.csv` (copied from MT5 Common Files when found)
- `tester_journal.log` (copied from MT5 tester logs)

## Trade Log Analysis
Example:

```bash
python tools/analyze_trade_log.py --log outputs/mt5_runs/baseline_run_001/trade_log.csv --output-prefix outputs/analysis/baseline
```

Outputs:
- `outputs/analysis/baseline.json`
- `outputs/analysis/baseline_monthly.csv`
- `outputs/analysis/baseline_gate_stats.csv`

## Split Aggregation and Acceptance
Example:

```bash
python tools/aggregate_splits.py --runs-dir outputs/mt5_runs --output-prefix outputs/analysis/split_summary
```

Default acceptance checks:
- Combined window: `PF > 2.0`, `DD <= 15%`, `trades >= 300`
- Regime OOS window: `PF >= 1.2`, `DD <= 20%`
- WFO stability: at least `60%` folds with `PF >= 1.4`, and no catastrophic fold (`PF < 1.0` with `DD > 25%`)
