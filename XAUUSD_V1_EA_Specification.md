XAUUSD_V1_EA_Specification.md
Technical Coding Blueprint for MQL5 (Codex GPT-5.3 Ready)
1. Project Overview

EA Name: XAUUSD_V1_VolatilityTrend
Platform: MetaTrader 5
Language: MQL5
Primary Symbol: XAUUSD
Primary Timeframe: H1
Trend Timeframe: H4

This EA implements a volatility-adaptive trend continuation strategy with pullback entry and structured trade management.

2. System Architecture Overview
Core Modules

Initialization Module

Market Regime Filter

Trend Detection Engine (H4)

Entry Engine (H1)

Risk & Position Sizing Engine

Trade Management Engine

Kill Switch Module

Time Filter Module

Utility Functions

All logic must be modularized into functions.

3. Input Parameters
// === Trend Settings ===
input int InpFastEMA_H4 = 50;
input int InpSlowEMA_H4 = 200;

// === Entry Settings ===
input int InpRSIPeriod = 14;
input int InpATRPeriod = 14;

// === Risk Settings ===
input double InpRiskPercent = 0.75;
input double InpATR_SL_Mult = 2.2;
input double InpATR_Trail_Mult = 1.8;

// === SL Constraints ===
input int InpMinSL_Points = 250;
input int InpMaxSL_Points = 600;

// === Filters ===
input int InpMaxSpread = 30;
input double InpMaxDailyLossPercent = 2.0;
input bool InpUseTimeFilter = true;
input int InpStartHour = 7;
input int InpEndHour = 18;
4. Indicator Handles (OnInit)

Create indicator handles:

iMA() for H4 Fast EMA
iMA() for H4 Slow EMA
iRSI() for H1
iATR() for H1
iATR() for H4

Store handles globally.

Release in OnDeinit().

5. Market Regime Filter Logic

Function:

bool IsMarketTradable()
Conditions:

Current spread ≤ InpMaxSpread

Not within rollover hour (23:00–00:00)

H4 ATR > (Median ATR × 0.8)

Approximate median with 200-period simple average ATR

If any fails → return false.

6. Trend Detection Engine (H4)

Function:

int GetTrendDirection()

Returns:

1 → Bullish

-1 → Bearish

0 → No trend

Bullish:

Close[1] > EMA200

EMA50 > EMA200

Previous H4 candle bullish

Bearish:

Mirror logic.

7. Entry Engine (H1 Pullback)

Function:

bool CheckLongEntry()
bool CheckShortEntry()
Long Conditions:

Trend == 1

Price near EMA50 (within 0.5 ATR distance)

RSI between 40–50

Bullish candle close (Close > Open)

Short Conditions:

Mirror.

Only execute at new candle open (use static datetime check).

8. Stop Loss Calculation

Function:

double CalculateStopLossPoints()

Logic:

SL = ATR(H1) × InpATR_SL_Mult

Apply constraints:

if SL < InpMinSL_Points → SL = Min
if SL > InpMaxSL_Points → SL = Max

Return SL in points.

9. Position Sizing Engine

Function:

double CalculateLotSize(double stopLossPoints)

Formula:

RiskAmount = AccountBalance() × (InpRiskPercent / 100)
LotSize = RiskAmount / (stopLossPoints × PointValuePerLot)

Normalize to broker lot step and minimum.

10. Order Execution

Use CTrade class.

Before placing order:

Ensure no more than 1 trade per direction

Ensure total open trades ≤ 2

Place market order with:

Calculated SL

No fixed TP (managed dynamically)

11. Trade Management Engine

Function:

void ManageOpenPositions()

For each position:

Step 1 – Break Even

If profit ≥ 1R:
Move SL to entry price.

Step 2 – Partial Close

If profit ≥ 1.5R:
Close 50% of volume once.

Track partial via position comment or global variable.

Step 3 – ATR Trailing

After BE triggered:

NewSL = CurrentPrice − (ATR × InpATR_Trail_Mult)

Update only if new SL improves.

12. Kill Switch Module

Track:

Daily realized loss

Consecutive losses

Reset counters at new day.

If:

Daily loss ≥ InpMaxDailyLossPercent
OR

Consecutive losses ≥ 2

Then:

Disable new entries until next trading day.

13. Time Filter Module

Function:

bool IsWithinTradingHours()

If InpUseTimeFilter == false → return true.

Otherwise:

Check server hour between InpStartHour and InpEndHour.

14. Execution Flow (OnTick)
OnTick():

if !IsMarketTradable() → return
if !IsWithinTradingHours() → return
if KillSwitchActive → return

if NewCandle():
    trend = GetTrendDirection()

    if trend == 1 and CheckLongEntry():
        ExecuteBuy()

    if trend == -1 and CheckShortEntry():
        ExecuteSell()

ManageOpenPositions()
15. Safety Rules

Never trade during spread spikes

Never place trade without SL

Never modify SL backward

All price values normalized using NormalizeDouble()

16. Backtesting Configuration

Strategy Tester:

Model: Every Tick (Real Ticks)

Period: 2018–2025

Initial Balance: 10,000

Leverage: 1:100

17. Performance Validation Checklist

After backtest, record:

Profit Factor

Net Profit

Max Drawdown %

Recovery Factor

Total Trades

Equity Curve Smoothness

Reject system if:

Trades < 300

PF > 3.5 (overfit suspicion)

DD > 30%

18. Coding Standards for Codex GPT-5.3

Strict mode enabled

Modular function-based structure

Clear comments for each block

Avoid global state misuse

Use ENUM_POSITION_TYPE checks

Use PositionSelect() safely

Use HistorySelect() for daily loss tracking

19. Future Version Hooks (Leave Placeholders)

News filter integration

Regime-based ATR multiplier switching

Multi-session bias engine

Liquidity sweep detection

Dynamic risk adjustment

End of Specification