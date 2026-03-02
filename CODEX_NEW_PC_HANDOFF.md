# Codex Handoff For New PC

Date: 2026-03-02

## 1) Project Identity
- Repo: `https://github.com/Priyanshu123496/sminds-mql-robos.git`
- Branch: `main`
- Latest known commit in this thread: `9ad3e6aad45d7bab1dc6c6e81ca9b198bcc4fc4d`
- Primary working folder for this thread: `C:\SMINDS\projects\sminds-mql-robos`

## 2) Current EA Focus
- Active production EA file:
  - `mt5\Production Ready EA\TTR-X.mq5`
- Compiled output:
  - `mt5\Production Ready EA\TTR-X.ex5`

## 3) Important Logic Decisions Already Made
- `TTR-X` is obfuscated and branded for production.
- Fast/Slow/Filter EMA decoding is now strict formula-only.
- Legacy bypass `InpP2=1984 -> FastEMA=50` was removed.

## 4) Exact Encode/Decode Formulas In TTR-X
- Encode:
  - `InpP2 = ((FastEMA + 11) * 17) ^ 913`
  - `InpP3 = ((SlowEMA + 17) * 19) ^ 1291`
  - `InpP4 = ((FilterEMA + 23) * 29) ^ 2087`
- Decode:
  - `FastEMA = ((InpP2 ^ 913) / 17) - 11`
  - `SlowEMA = ((InpP3 ^ 1291) / 19) - 17`
  - `FilterEMA = ((InpP4 ^ 2087) / 29) - 23`
- Validation:
  - `(InpP2 ^ 913) % 17 == 0`
  - `(InpP3 ^ 1291) % 19 == 0`
  - `(InpP4 ^ 2087) % 29 == 0`

Example for Fast=50, Slow=75, Filter=200:
- `InpP2=1948`, `InpP3=991`, `InpP4=4452`

## 5) Helper Utility
- File: `mt5\Production Ready EA\ttrx_param_helper.py`
- Usage:
  - Encode:
    - `python "mt5\Production Ready EA\ttrx_param_helper.py" encode --fast 50 --slow 75 --filter 200`
  - Decode:
    - `python "mt5\Production Ready EA\ttrx_param_helper.py" decode --p2 1948 --p3 991 --p4 4452`

## 6) Compile TTR-X On Windows
- MetaEditor path expected:
  - `C:\Program Files\MetaTrader 5\metaeditor64.exe`
- Compile command:
  - `& "C:\Program Files\MetaTrader 5\metaeditor64.exe" /compile:"C:\SMINDS\projects\sminds-mql-robos\mt5\Production Ready EA\TTR-X.mq5" /log:"C:\SMINDS\projects\sminds-mql-robos\mt5\Production Ready EA\TTR-X.compile.log"`

If needed for MT5 terminal usage, copy to terminal Experts path and compile there as well.

## 7) MT5 Research Data Context
- Raw CSV source folder:
  - `mt5\Raw Data`
- Research scripts folder:
  - `mt5\scripts\research`
- A CSV-to-SQLite ingest run was executed in this thread under:
  - `mt5\research_runs\20260301_230927`
- The 48-candidate search was started but aborted by user interruption.

## 8) Git Status In This Thread
- Git was initialized in this folder and pushed to remote successfully.
- `.gitignore` was updated to avoid committing large local artifacts (`.venv`, `node_modules`, `.expo`, `dist`, `mt5/research_runs`, raw CSV, db/sqlite files).

## 9) Bootstrap On New PC (Quick)
1. Clone repo:
   - `git clone https://github.com/Priyanshu123496/sminds-mql-robos.git C:\SMINDS\projects\sminds-mql-robos`
2. Open folder in VS Code.
3. Ensure MT5 + MetaEditor are installed.
4. Re-run compile command from section 6.
5. Continue from this handoff + active files.

## 10) Ready-To-Paste Prompt For New Codex Session
```text
Use C:\SMINDS\projects\sminds-mql-robos as the primary workspace for this thread.

Read and follow:
C:\SMINDS\projects\sminds-mql-robos\CODEX_NEW_PC_HANDOFF.md

Current priority:
1) Work on mt5\Production Ready EA\TTR-X.mq5
2) Keep strict EMA formula decoding (no legacy bypass)
3) Compile and test TTR-X.ex5 as needed
4) If asked, resume research pipeline from mt5\scripts\research using mt5\Raw Data
```

