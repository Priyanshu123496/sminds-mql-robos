# Chat Handoff: XAUUSD EA Research (MT5)

Generated: 2026-02-25 (local)
Workspace: `c:\SMINDS\Projects\sminds-mql-robos`

## 1) Objective You Set
Build a production-ready XAUUSD EA with monthly behavior:
- PF > 1.75
- Drawdown < 20%
- Trades > 20 per month
- Net profit target around +60% to +70% in a month

## 2) What Was Implemented
### EA
- Rebuilt and upgraded:
  - `Experts/XAUUSD_V1_VolatilityTrend.mq5`
- Compile status:
  - `outputs/v1_compile.log` -> `Result: 0 errors, 0 warnings`

### Monthly Tooling Added
- `tools/score_monthly.py`
- `tools/validate_v1_monthly.ps1`
- `tools/research_v1_monthly.ps1`

### Profiles
- Production-attempt profile:
  - `profiles/xauusd_v1_prod_monthly_v1.set`
  - `profiles/xauusd_v1_prod_monthly_v1.meta.json`
- Targeted monthly-hit profile:
  - `profiles/xauusd_v1_monthly_60_70_v1.set`
  - `profiles/xauusd_v1_monthly_60_70_v1.meta.json`

## 3) Latest Results
### A) Production-attempt profile (`xauusd_v1_prod_monthly_v1`)
Validation summary:
- `outputs/validation/xauusd_v1_prod_monthly_v1_validation/validation_summary.json`
- `outputs/validation/xauusd_v1_prod_monthly_v1_validation/validation_summary.csv`

Key metrics:
- classification: `niche-profile`
- months_passed: `0/12`
- median_monthly_balance_ratio: `1.233319`
- median_monthly_pf: `1.264848`
- worst_month_dd_pct: `44.7371`

### B) Targeted profile (`xauusd_v1_monthly_60_70_v1`)
Validation summary:
- `outputs/validation/xauusd_v1_c167_r022_validation/validation_summary.json`
- `outputs/validation/xauusd_v1_c167_r022_validation/validation_summary.csv`

Key metrics:
- classification: `niche-profile`
- months_passed: `1/12`
- Passed month: `2025-10`
  - PF: `2.08484`
  - DD: `6.5598%`
  - Trades: `72`
  - Balance ratio: `1.662376` (+66.24%)

Interpretation:
- Monthly target is achievable in specific regime months.
- Not yet robust enough for broad production across 12 months.

## 4) Research Artifacts
- `outputs/research/xauusd_v1_monthly_prod_r1/candidate_scores.csv`
- `outputs/research/xauusd_v1_monthly_prod_r1/candidate_scores.json`
- `outputs/research/xauusd_v1_monthly_prod_r1/chosen_steps.json`
- `outputs/research/xauusd_v1_monthly_prod_r1/research_summary.json`

## 5) Reproduce / Continue Commands
### Monthly validation for a set
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\validate_v1_monthly.ps1 \
  -SetFile profiles\xauusd_v1_monthly_60_70_v1.set \
  -Expert XAUUSD_V1_VolatilityTrend.ex5 \
  -ExpertLogPrefix XAUUSD_V1_VolatilityTrend \
  -OutputLabel xauusd_v1_c167_r022_validation \
  -CloseRunningTerminal \
  -ObjectiveRatio 1.6 -MonthlyPfMin 1.75 -MonthlyDdMax 20 -MonthlyTradesMin 20 \
  -MonthsPassMin 8 -MonthsTradesMin 10 -CatastrophicDdMax 30
```

### Run staged monthly research
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\research_v1_monthly.ps1 \
  -BaseSetFile profiles\xauusd_v1_prod_monthly_v1.set \
  -Expert XAUUSD_V1_VolatilityTrend.ex5 \
  -ExpertLogPrefix XAUUSD_V1_VolatilityTrend \
  -OutputLabel xauusd_v1_monthly_prod_r1 \
  -CloseRunningTerminal
```

## 6) Suggested Next Prompt for ChatGPT
Use this exact prompt in ChatGPT and upload the files listed below:

> Continue this MT5 XAUUSD monthly EA research. Goal: improve robustness so at least 6/12 months meet PF>1.75, DD<20%, trades>20, and target monthly ratio 1.6-1.7. Keep one-position-only policy. Start from `profiles/xauusd_v1_monthly_60_70_v1.set`, perform structural improvements in `Experts/XAUUSD_V1_VolatilityTrend.mq5`, then run `tools/validate_v1_monthly.ps1` and provide updated profile + validation artifacts.

## 7) Files to Upload into ChatGPT
- `CHAT_HANDOFF.md`
- `XAUUSD_V1_EA_Specification.md`
- `Experts/XAUUSD_V1_VolatilityTrend.mq5`
- `profiles/xauusd_v1_monthly_60_70_v1.set`
- `profiles/xauusd_v1_monthly_60_70_v1.meta.json`
- `outputs/validation/xauusd_v1_c167_r022_validation/validation_summary.json`
- `outputs/validation/xauusd_v1_c167_r022_validation/validation_summary.csv`
- `outputs/research/xauusd_v1_monthly_prod_r1/candidate_scores.csv`
- `outputs/research/xauusd_v1_monthly_prod_r1/chosen_steps.json`

