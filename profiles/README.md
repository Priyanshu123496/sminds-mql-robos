# Profiles

This directory stores preset-based strategy profiles for `XAUUSD_RobustBreakout`.

## `pf2_window_0607_v1`

- Source preset: `outputs/sets/pf2_best_b10_c15.set`
- Promoted preset: `profiles/pf2_window_0607_v1.set`
- Validation snapshot: PF `2.234899`, DD `11.1788%`, Trades `35`
- Validation window: `2025.08.01` to `2026.02.22`

Notes:
- This is a narrow-session profile (`SessionStartServerHour=6`, `SessionEndServerHour=7`).
- It is intended for preset-driven runs only.
- It does not change EA source defaults in `Experts/XAUUSD_RobustBreakout.mq5`.
- Use `tools/validate_profile.ps1` for robustness classification (`production-candidate` vs `niche-profile`).

## `pf2_window_0607_v2`

- Source flow: automatic fallback re-search from `tools/research_pf2_v2.ps1`
- Promoted preset: `profiles/pf2_window_0607_v2.set`
- Final validation: `outputs/validation/pf2_window_0607_v2_validation/validation_summary.json`
- Validation classification: `niche-profile`

Selected tuning deltas vs `v1`:
- `SessionStartServerHour=5`
- `SessionEndServerHour=7`
- `BE_Trigger_R=0.7`
- `TrailStart_R=0.9`
- `TrailATR=0.9`
- `MaxAtrToPricePct=0.40`
