# MT5 Research Pipeline

This folder contains the end-to-end research workflow for:

- Pulling `XAUUSD` M1 data from MT5 into SQLite.
- Building regime features for strategy narrowing.
- Running staged backtest search against the research EA.
- Selecting final candidates and exporting `.set` files.

## Main entrypoint

```powershell
python mt5\scripts\research\run_full_research_pipeline.py `
  --repo-root C:\SMINDS\projects\sminds-mql-robos `
  --symbol XAUUSD `
  --from-date 2021-01-01 `
  --to-date 2025-12-31 `
  --strategy-tf M15 `
  --deposit 25000 `
  --leverage 1:1000 `
  --lot 1.0 `
  --target-quarter-net 25000
```

## Generated outputs

All outputs are written under:

`mt5\research_runs\<RUN_ID>\`

Key files:

- `data\xauusd_m1.sqlite`
- `summaries\ingestion_summary.json`
- `summaries\regime_overview.csv`
- `summaries\quarterly_scoreboard.csv`
- `summaries\top_candidates.csv`
- `summaries\final_recommendation.md`
- `artifacts\sets\candidate_<id>.set`
