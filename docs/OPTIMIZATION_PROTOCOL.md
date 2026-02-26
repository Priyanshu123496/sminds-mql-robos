# Optimization and Validation Protocol

## Objective
- Primary target: `PF > 2.0` with `max DD <= 15%`.
- Regime hard-OOS guardrail (`2025-11-01` to `2026-02-22`): `PF >= 1.20`, `DD <= 20%`.
- Stability gate: at least `60%` WFO folds with `PF >= 1.4`, and no fold with `PF < 1.0` and `DD > 25%`.

## Required Test Engine
- MT5 Strategy Tester using real ticks (`Model=4`).
- Single symbol: `XAUUSD`.
- Signal timeframe: `M15`.
- Trend context: `H1`.

## Structural Filters Enabled
- Bar-close confirmation mode (`UseBarCloseConfirmation=true`).
- Breakout excess gate (`MinBreakoutExcessAtr`).
- Trend slope gate (`abs(EMA50-EMA200)/ATR >= MinTrendSlopeAtr`).
- ATR percentile gate (`MinAtrPercentile..MaxAtrPercentile` over `VolatilityLookbackBars`).
- Re-entry pullback lock (`ReentryLockBars` or pullback by `ReentryPullbackAtr * ATR`).

## Stage Sequence
1. Baseline reproducibility:
   - Run existing set on `2025-08-01..2026-02-22`.
   - Archive as `baseline_run_001`.
2. Structural sanity:
   - Confirm lower churn in Nov-2025..Feb-2026 using `analyze_trade_log.py`.
   - Inspect `GATE_STATS` and `REGIME_STATS`.
3. Coarse optimization (grid/genetic):
   - `DonchianBars: 20..60 step 10`
   - `BreakoutBufferATR: 0.15..0.35 step 0.05`
   - `AdxMin: 22..30 step 2`
   - `SL_ATR: 2.0..3.0 step 0.2`
   - `TP_ATR: 2.8..4.8 step 0.2`
   - `CooldownBarsAfterLoss: 2..5 step 1`
   - `MaxAtrToPricePct: 0.25..0.45 step 0.05`
   - `MinTrendSlopeAtr: 0.10..0.40 step 0.05`
   - `MaxAtrPercentile: 75..90 step 5`
4. Local refinement:
   - Restrict to top stable clusters from Stage 3.
5. Walk-forward:
   - `18m train / 6m test`, step `3m`, across 2020-2026.
6. Hard regime OOS:
   - Fixed run on `2025-11-01..2026-02-22`.

## Automation Workflow
1. Run each split with `tools/run_mt5_backtest.ps1`.
   - Use `-CloseRunningTerminal` for deterministic `/config` execution.
   - MT5 HTML report is captured when available; XML fallback is generated from `trade_log.csv` if MT5 XML is not emitted.
2. Analyze trade logs with `tools/analyze_trade_log.py`.
3. Aggregate split outcomes with `tools/aggregate_splits.py`.
4. Optional XML-only fold summary with `tools/wfo_summary.py`.

## Acceptance Checkpoints
- Combined run: `PF > 2.0`, `DD <= 15%`, `trades >= 300`.
- Regime hard-OOS run: `PF >= 1.20`, `DD <= 20%`.
- WFO stability:
  - pass ratio (`PF >= 1.4`) >= `60%`
  - no catastrophic fold (`PF < 1.0` and `DD > 25%`).
