#property copyright "SMINDS"
#property version   "1.00"
#property strict
#property description "XAUUSD robust volatility breakout EA"

#include <Trade/Trade.mqh>

#define EA_MAGIC 26022101
#define NEWS_POLL_SECONDS 60

enum ENUM_ENTRY_TRIGGER_MODE
{
   ENTRY_TRIGGER_INTRABAR = 0,
   ENTRY_TRIGGER_BAR_CLOSE = 1,
   ENTRY_TRIGGER_BAR_OPEN = 2
};

enum EntryRejectReason
{
   REJECT_POSITION_OPEN = 0,
   REJECT_TRIGGER_MODE_WAIT,
   REJECT_SIGNAL_BAR_UNAVAILABLE,
   REJECT_ALREADY_TRADED_BAR,
   REJECT_COOLDOWN,
   REJECT_REENTRY_LOCK,
   REJECT_SESSION,
   REJECT_FRIDAY_FLAT,
   REJECT_SPREAD,
   REJECT_NEWS,
   REJECT_ATR_INVALID,
   REJECT_VOL_PCTL,
   REJECT_VOLATILITY,
   REJECT_ADX_LOW,
   REJECT_TREND_INVALID,
   REJECT_TREND_SLOPE,
   REJECT_DONCHIAN_INVALID,
   REJECT_QUOTES_INVALID,
   REJECT_NO_CROSS,
   REJECT_BREAKOUT_EXCESS,
   REJECT_BREAKOUT_NOT_REACHED,
   REJECT_COUNT
};

struct GateStats
{
   ulong attempts;
   ulong signals_passed;
   ulong entries;
   ulong rejects[REJECT_COUNT];
};

struct RegimeStats
{
   ulong trades;
   ulong wins;
   ulong losses;
   double net_profit;
};

input ENUM_TIMEFRAMES SignalTF = PERIOD_M15;
input ENUM_TIMEFRAMES TrendTF = PERIOD_H1;
input double RiskPerTradePct = 0.5;
input int DonchianBars = 40;
input int AtrPeriod = 14;
input double BreakoutBufferATR = 0.20;
input int AdxPeriod = 14;
input double AdxMin = 22.0;
input int EmaFast = 50;
input int EmaSlow = 200;
input double SL_ATR = 1.8;
input double TP_ATR = 2.6;
input double BE_Trigger_R = 1.0;
input double TrailStart_R = 1.2;
input double TrailATR = 1.1;
input int MaxBarsInTrade = 32;
input bool UseNewsFilter = true;
input int NewsBlockBeforeMin = 45;
input int NewsBlockAfterMin = 30;
input string NewsCurrencies = "USD";
input int SessionStartServerHour = 10;
input int SessionEndServerHour = 22;
input int FridayFlatHour = 21;
input int FridayFlatMinute = 45;
input int MaxSpreadPoints = 350;
input double CommissionPerLotRT = 7.0;
input ENUM_ENTRY_TRIGGER_MODE EntryTriggerMode = ENTRY_TRIGGER_BAR_CLOSE;
input bool EnableGateDiagnostics = true;
input int DiagnosticsPrintIntervalBars = 96;
input int MinTradesForScore = 300;
input double MaxAtrToPricePct = 0.30;
input int CooldownBarsAfterLoss = 3;
input int CooldownBarsAfterWin = 0;
input bool RequireCrossingSignal = true;
input bool UseTrendSlopeFilter = true;
input double MinTrendSlopeAtr = 0.20;
input bool UseVolatilityPercentileFilter = true;
input int VolatilityLookbackBars = 240;
input double MaxAtrPercentile = 85.0;
input double MinAtrPercentile = 20.0;
input bool UseReentryPullbackLock = true;
input int ReentryLockBars = 6;
input double ReentryPullbackAtr = 0.35;
input bool UseBarCloseConfirmation = true;
input double MinBreakoutExcessAtr = 0.10;

CTrade g_trade;

int g_atr_handle = INVALID_HANDLE;
int g_adx_handle = INVALID_HANDLE;
int g_ema_fast_handle = INVALID_HANDLE;
int g_ema_slow_handle = INVALID_HANDLE;

datetime g_last_signal_bar = 0;
int g_consecutive_emergency_spread = 0;
string g_news_currencies[];
datetime g_last_news_eval = 0;
bool g_news_blocked_cache = false;
ulong g_calendar_change_id = 0;
datetime g_last_calendar_poll = 0;
bool g_calendar_enabled = false;
string g_last_trade_bar_key = "";
double g_last_trade_bar = 0.0;
int g_log_handle = INVALID_HANDLE;
string g_log_file = "";
GateStats g_gate_stats;
int g_diag_bar_counter = 0;
datetime g_last_exit_bar = 0;
bool g_last_exit_was_loss = false;
int g_last_exit_trade_direction = 0;
double g_last_exit_price = 0.0;
double g_prev_bid = 0.0;
double g_prev_ask = 0.0;
bool g_prev_quotes_ready = false;
RegimeStats g_regime_early;
RegimeStats g_regime_late;

string ToUpperCopy(string value)
{
   StringToUpper(value);
   return value;
}

int VolumeDigits(const double step)
{
   int digits = 0;
   for(digits = 0; digits <= 8; digits++)
   {
      double scaled = step * MathPow(10.0, digits);
      if(MathAbs(scaled - MathRound(scaled)) < 1e-8)
         return digits;
   }
   return 8;
}

void ResetGateStats()
{
   g_gate_stats.attempts = 0;
   g_gate_stats.signals_passed = 0;
   g_gate_stats.entries = 0;
   for(int i = 0; i < REJECT_COUNT; i++)
      g_gate_stats.rejects[i] = 0;
}

void RecordReject(const EntryRejectReason reason)
{
   int idx = (int)reason;
   if(idx < 0 || idx >= REJECT_COUNT)
      return;
   g_gate_stats.rejects[idx]++;
}

string BuildGateSummary(const string label)
{
   double pass_rate = 0.0;
   double entry_conversion = 0.0;

   if(g_gate_stats.attempts > 0)
      pass_rate = 100.0 * ((double)g_gate_stats.signals_passed / (double)g_gate_stats.attempts);

   if(g_gate_stats.signals_passed > 0)
      entry_conversion = 100.0 * ((double)g_gate_stats.entries / (double)g_gate_stats.signals_passed);

   return StringFormat(
      "label=%s attempts=%I64u passed=%I64u entries=%I64u pass_rate_pct=%.2f entry_conv_pct=%.2f r_pos_open=%I64u r_bar_wait=%I64u r_bar_missing=%I64u r_already_bar=%I64u r_cooldown=%I64u r_reentry=%I64u r_session=%I64u r_friday=%I64u r_spread=%I64u r_news=%I64u r_atr=%I64u r_vol_pctl=%I64u r_volatility=%I64u r_adx=%I64u r_trend=%I64u r_trend_slope=%I64u r_donchian=%I64u r_quotes=%I64u r_no_cross=%I64u r_breakout_excess=%I64u r_breakout=%I64u",
      label,
      g_gate_stats.attempts,
      g_gate_stats.signals_passed,
      g_gate_stats.entries,
      pass_rate,
      entry_conversion,
      g_gate_stats.rejects[REJECT_POSITION_OPEN],
      g_gate_stats.rejects[REJECT_TRIGGER_MODE_WAIT],
      g_gate_stats.rejects[REJECT_SIGNAL_BAR_UNAVAILABLE],
      g_gate_stats.rejects[REJECT_ALREADY_TRADED_BAR],
      g_gate_stats.rejects[REJECT_COOLDOWN],
      g_gate_stats.rejects[REJECT_REENTRY_LOCK],
      g_gate_stats.rejects[REJECT_SESSION],
      g_gate_stats.rejects[REJECT_FRIDAY_FLAT],
      g_gate_stats.rejects[REJECT_SPREAD],
      g_gate_stats.rejects[REJECT_NEWS],
      g_gate_stats.rejects[REJECT_ATR_INVALID],
      g_gate_stats.rejects[REJECT_VOL_PCTL],
      g_gate_stats.rejects[REJECT_VOLATILITY],
      g_gate_stats.rejects[REJECT_ADX_LOW],
      g_gate_stats.rejects[REJECT_TREND_INVALID],
      g_gate_stats.rejects[REJECT_TREND_SLOPE],
      g_gate_stats.rejects[REJECT_DONCHIAN_INVALID],
      g_gate_stats.rejects[REJECT_QUOTES_INVALID],
      g_gate_stats.rejects[REJECT_NO_CROSS],
      g_gate_stats.rejects[REJECT_BREAKOUT_EXCESS],
      g_gate_stats.rejects[REJECT_BREAKOUT_NOT_REACHED]
   );
}

void EmitGateDiagnostics(const string label, const bool write_csv)
{
   if(!EnableGateDiagnostics)
      return;

   string summary = BuildGateSummary(label);
   Print(summary);

   if(write_csv)
      LogEvent("GATE_STATS", label, "-", 0.0, 0.0, 0.0, 0.0, summary);
}

void MaybeEmitPeriodicGateDiagnostics(const bool is_new_signal_bar)
{
   if(!EnableGateDiagnostics || !is_new_signal_bar)
      return;

   g_diag_bar_counter++;
   if(DiagnosticsPrintIntervalBars <= 0)
      return;

   if(g_diag_bar_counter >= DiagnosticsPrintIntervalBars)
   {
      EmitGateDiagnostics("periodic", true);
      g_diag_bar_counter = 0;
   }
}

void ResetRegimeStats(RegimeStats &stats)
{
   stats.trades = 0;
   stats.wins = 0;
   stats.losses = 0;
   stats.net_profit = 0.0;
}

datetime MakeDateTime(const int year,
                      const int month,
                      const int day,
                      const int hour,
                      const int minute,
                      const int second)
{
   MqlDateTime dt;
   dt.year = year;
   dt.mon = month;
   dt.day = day;
   dt.hour = hour;
   dt.min = minute;
   dt.sec = second;
   dt.day_of_week = 0;
   dt.day_of_year = 0;
   return StructToTime(dt);
}

bool IsInEarlyRegime(const datetime t)
{
   static datetime start_time = 0;
   static datetime end_time = 0;

   if(start_time == 0 || end_time == 0)
   {
      start_time = MakeDateTime(2025, 8, 1, 0, 0, 0);
      end_time = MakeDateTime(2025, 10, 31, 23, 59, 59);
   }

   return (t >= start_time && t <= end_time);
}

bool IsInLateRegime(const datetime t)
{
   static datetime start_time = 0;
   static datetime end_time = 0;

   if(start_time == 0 || end_time == 0)
   {
      start_time = MakeDateTime(2025, 11, 1, 0, 0, 0);
      end_time = MakeDateTime(2026, 2, 28, 23, 59, 59);
   }

   return (t >= start_time && t <= end_time);
}

void UpdateRegimeStats(const datetime deal_time, const double profit)
{
   if(IsInEarlyRegime(deal_time))
   {
      g_regime_early.trades++;
      g_regime_early.net_profit += profit;
      if(profit > 0.0)
         g_regime_early.wins++;
      else if(profit < 0.0)
         g_regime_early.losses++;
      return;
   }

   if(IsInLateRegime(deal_time))
   {
      g_regime_late.trades++;
      g_regime_late.net_profit += profit;
      if(profit > 0.0)
         g_regime_late.wins++;
      else if(profit < 0.0)
         g_regime_late.losses++;
   }
}

string BuildRegimeSummary(const string label)
{
   double early_win_rate = 0.0;
   double late_win_rate = 0.0;

   if(g_regime_early.trades > 0)
      early_win_rate = 100.0 * ((double)g_regime_early.wins / (double)g_regime_early.trades);

   if(g_regime_late.trades > 0)
      late_win_rate = 100.0 * ((double)g_regime_late.wins / (double)g_regime_late.trades);

   return StringFormat(
      "label=%s early_period=2025-08_to_2025-10 early_trades=%I64u early_wins=%I64u early_losses=%I64u early_win_rate_pct=%.2f early_net=%.2f late_period=2025-11_to_2026-02 late_trades=%I64u late_wins=%I64u late_losses=%I64u late_win_rate_pct=%.2f late_net=%.2f",
      label,
      g_regime_early.trades,
      g_regime_early.wins,
      g_regime_early.losses,
      early_win_rate,
      g_regime_early.net_profit,
      g_regime_late.trades,
      g_regime_late.wins,
      g_regime_late.losses,
      late_win_rate,
      g_regime_late.net_profit
   );
}

void EmitRegimeDiagnostics(const string label, const bool write_csv)
{
   if(!EnableGateDiagnostics)
      return;

   string summary = BuildRegimeSummary(label);
   Print(summary);

   if(write_csv)
      LogEvent("REGIME_STATS", label, "-", 0.0, 0.0, 0.0, 0.0, summary);
}

void ParseNewsCurrencies()
{
   ArrayResize(g_news_currencies, 0);

   string clean = NewsCurrencies;
   StringReplace(clean, " ", "");

   if(StringLen(clean) == 0)
   {
      ArrayResize(g_news_currencies, 1);
      g_news_currencies[0] = "USD";
      return;
   }

   int count = StringSplit(clean, ',', g_news_currencies);
   if(count <= 0)
   {
      ArrayResize(g_news_currencies, 1);
      g_news_currencies[0] = "USD";
      return;
   }

   for(int i = 0; i < count; i++)
      g_news_currencies[i] = ToUpperCopy(g_news_currencies[i]);
}

bool IsCurrencySelected(const string currency)
{
   string upper = ToUpperCopy(currency);
   int count = ArraySize(g_news_currencies);

   for(int i = 0; i < count; i++)
   {
      if(upper == g_news_currencies[i])
         return true;
   }

   return false;
}

bool InitTradeLog()
{
   string stamp = TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS);
   StringReplace(stamp, ":", "-");
   StringReplace(stamp, ".", "-");
   StringReplace(stamp, " ", "_");

   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   g_log_file = StringFormat("XAUUSD_RobustBreakout_%I64d_%s.csv", login, stamp);
   g_log_handle = FileOpen(g_log_file, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ';');

   if(g_log_handle == INVALID_HANDLE)
   {
      PrintFormat("Unable to open log file '%s' (err=%d)", g_log_file, GetLastError());
      return false;
   }

   FileWrite(g_log_handle,
             "timestamp",
             "event",
             "reason",
             "symbol",
             "type",
             "volume",
             "price",
             "sl",
             "tp",
             "spread_points",
             "equity",
             "balance",
             "comment");
   FileFlush(g_log_handle);
   return true;
}

void LogEvent(const string event_name,
              const string reason,
              const string side,
              const double volume,
              const double price,
              const double sl,
              const double tp,
              const string comment)
{
   if(g_log_handle == INVALID_HANDLE)
      return;

   FileWrite(g_log_handle,
             TimeToString(TimeTradeServer(), TIME_DATE | TIME_SECONDS),
             event_name,
             reason,
             _Symbol,
             side,
             DoubleToString(volume, 2),
             DoubleToString(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
             DoubleToString(sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
             DoubleToString(tp, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
             (string)GetSpreadPoints(),
             DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2),
             DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2),
             comment);
   FileFlush(g_log_handle);
}

bool InitIndicators()
{
   g_atr_handle = iATR(_Symbol, SignalTF, AtrPeriod);
   g_adx_handle = iADX(_Symbol, SignalTF, AdxPeriod);
   g_ema_fast_handle = iMA(_Symbol, TrendTF, EmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_ema_slow_handle = iMA(_Symbol, TrendTF, EmaSlow, 0, MODE_EMA, PRICE_CLOSE);

   if(g_atr_handle == INVALID_HANDLE ||
      g_adx_handle == INVALID_HANDLE ||
      g_ema_fast_handle == INVALID_HANDLE ||
      g_ema_slow_handle == INVALID_HANDLE)
   {
      Print("Failed to initialize one or more indicator handles.");
      return false;
   }

   return true;
}

void ReleaseIndicators()
{
   if(g_atr_handle != INVALID_HANDLE)
      IndicatorRelease(g_atr_handle);
   if(g_adx_handle != INVALID_HANDLE)
      IndicatorRelease(g_adx_handle);
   if(g_ema_fast_handle != INVALID_HANDLE)
      IndicatorRelease(g_ema_fast_handle);
   if(g_ema_slow_handle != INVALID_HANDLE)
      IndicatorRelease(g_ema_slow_handle);
}

bool ReadBufferValue(const int handle, const int buffer, const int shift, double &value)
{
   double data[];
   int copied = CopyBuffer(handle, buffer, shift, 1, data);
   if(copied != 1)
      return false;

   value = data[0];
   return MathIsValidNumber(value);
}

bool GetCurrentBidAsk(double &bid, double &ask)
{
   if(!SymbolInfoDouble(_Symbol, SYMBOL_BID, bid))
      return false;
   if(!SymbolInfoDouble(_Symbol, SYMBOL_ASK, ask))
      return false;

   return (bid > 0.0 && ask > 0.0 && ask >= bid);
}

int GetSpreadPoints()
{
   double bid = 0.0;
   double ask = 0.0;

   if(!GetCurrentBidAsk(bid, ask) || _Point <= 0.0)
      return 0;

   return (int)MathRound((ask - bid) / _Point);
}

double NormalizePrice(const double price)
{
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

double NormalizeVolume(const double raw_volume)
{
   double min_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volume_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(volume_step <= 0.0)
      return 0.0;

   double clipped = MathMax(min_volume, MathMin(max_volume, raw_volume));
   double stepped = MathFloor(clipped / volume_step) * volume_step;
   int digits = VolumeDigits(volume_step);

   return NormalizeDouble(stepped, digits);
}

double CalculateVolume(const double stop_distance)
{
   if(stop_distance <= 0.0)
      return 0.0;

   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tick_size <= 0.0 || tick_value <= 0.0)
      return 0.0;

   double risk_amount = AccountInfoDouble(ACCOUNT_EQUITY) * (RiskPerTradePct / 100.0);
   if(risk_amount <= 0.0)
      return 0.0;

   double ticks_to_sl = stop_distance / tick_size;
   double loss_per_lot = (ticks_to_sl * tick_value) + CommissionPerLotRT;
   if(loss_per_lot <= 0.0)
      return 0.0;

   double raw_volume = risk_amount / loss_per_lot;
   return NormalizeVolume(raw_volume);
}

bool IsWithinSession(const datetime now)
{
   MqlDateTime dt;
   TimeToStruct(now, dt);

   int now_minutes = dt.hour * 60 + dt.min;
   int start_minutes = SessionStartServerHour * 60;
   int end_minutes = SessionEndServerHour * 60;

   if(start_minutes == end_minutes)
      return true;

   if(start_minutes < end_minutes)
      return (now_minutes >= start_minutes && now_minutes < end_minutes);

   return (now_minutes >= start_minutes || now_minutes < end_minutes);
}

bool IsFridayFlatTime(const datetime now)
{
   MqlDateTime dt;
   TimeToStruct(now, dt);

   if(dt.day_of_week != 5)
      return false;

   if(dt.hour > FridayFlatHour)
      return true;

   if(dt.hour < FridayFlatHour)
      return false;

   return (dt.min >= FridayFlatMinute);
}

bool IsNewSignalBar(datetime &bar_time)
{
   datetime bars[];
   ArraySetAsSeries(bars, true);

   if(CopyTime(_Symbol, SignalTF, 0, 2, bars) < 2)
      return false;

   bar_time = bars[0];

   if(g_last_signal_bar == 0)
   {
      g_last_signal_bar = bar_time;
      return false;
   }

   if(bar_time != g_last_signal_bar)
   {
      g_last_signal_bar = bar_time;
      return true;
   }

   return false;
}

ENUM_ENTRY_TRIGGER_MODE GetEffectiveEntryTriggerMode()
{
   if(UseBarCloseConfirmation)
      return ENTRY_TRIGGER_BAR_CLOSE;
   return EntryTriggerMode;
}

bool GetAtrPercentile(const double atr_value, double &percentile)
{
   percentile = 0.0;

   if(VolatilityLookbackBars < 20 || atr_value <= 0.0)
      return false;

   double atr_values[];
   int copied = CopyBuffer(g_atr_handle, 0, 1, VolatilityLookbackBars, atr_values);
   if(copied < 20)
      return false;

   int valid = 0;
   int less_or_equal = 0;

   for(int i = 0; i < copied; i++)
   {
      double value = atr_values[i];
      if(!MathIsValidNumber(value) || value <= 0.0)
         continue;

      valid++;
      if(value <= atr_value)
         less_or_equal++;
   }

   if(valid < 20)
      return false;

   percentile = 100.0 * ((double)less_or_equal / (double)valid);
   return true;
}

bool IsAtrPercentileAllowed(const double atr, double &atr_percentile)
{
   atr_percentile = 0.0;
   if(!UseVolatilityPercentileFilter)
      return true;

   if(!GetAtrPercentile(atr, atr_percentile))
      return false;

   double min_p = MathMin(MinAtrPercentile, MaxAtrPercentile);
   double max_p = MathMax(MinAtrPercentile, MaxAtrPercentile);
   return (atr_percentile >= min_p && atr_percentile <= max_p);
}

void InitLastTradeBarState()
{
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   g_last_trade_bar_key = StringFormat("RB_LAST_BAR_%I64d_%s", login, _Symbol);

   if(GlobalVariableCheck(g_last_trade_bar_key))
      g_last_trade_bar = GlobalVariableGet(g_last_trade_bar_key);
   else
      g_last_trade_bar = 0.0;
}

void SaveLastTradeBar(const datetime bar_time)
{
   g_last_trade_bar = (double)bar_time;
   GlobalVariableSet(g_last_trade_bar_key, g_last_trade_bar);
}

bool CanTradeThisBar(const datetime bar_time)
{
   return ((double)bar_time > g_last_trade_bar + 0.5);
}

bool IsReentryLocked(const int direction,
                     const datetime signal_bar,
                     const double atr,
                     const double reference_price)
{
   if(!UseReentryPullbackLock || direction == 0 || ReentryLockBars <= 0)
      return false;

   if(g_last_exit_trade_direction != direction)
      return false;

   if(g_last_exit_bar <= 0 || g_last_exit_price <= 0.0)
      return false;

   int tf_seconds = PeriodSeconds(SignalTF);
   if(tf_seconds <= 0)
      return false;

   int bars_since_exit = (int)((signal_bar - g_last_exit_bar) / tf_seconds);
   if(bars_since_exit >= ReentryLockBars)
      return false;

   double pullback_required = ReentryPullbackAtr * atr;
   if(pullback_required <= 0.0)
      return true;

   if(direction > 0)
      return (reference_price > (g_last_exit_price - pullback_required));

   return (reference_price < (g_last_exit_price + pullback_required));
}

bool GetDonchianLevels(double &highest, double &lowest)
{
   if(DonchianBars < 2)
      return false;

   double highs[];
   double lows[];

   int copied_high = CopyHigh(_Symbol, SignalTF, 1, DonchianBars, highs);
   int copied_low = CopyLow(_Symbol, SignalTF, 1, DonchianBars, lows);

   if(copied_high != DonchianBars || copied_low != DonchianBars)
      return false;

   highest = highs[0];
   lowest = lows[0];

   for(int i = 1; i < DonchianBars; i++)
   {
      if(highs[i] > highest)
         highest = highs[i];
      if(lows[i] < lowest)
         lowest = lows[i];
   }

   return true;
}

int CountStrategyPositions()
{
   int count = 0;
   int total = PositionsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != EA_MAGIC)
         continue;
      count++;
   }

   return count;
}

bool GetStrategyPosition(ulong &ticket,
                         long &type,
                         double &open_price,
                         double &sl,
                         double &tp,
                         double &volume,
                         datetime &open_time,
                         string &comment)
{
   int total = PositionsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(!PositionSelectByTicket(t))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != EA_MAGIC)
         continue;

      ticket = t;
      type = PositionGetInteger(POSITION_TYPE);
      open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      sl = PositionGetDouble(POSITION_SL);
      tp = PositionGetDouble(POSITION_TP);
      volume = PositionGetDouble(POSITION_VOLUME);
      open_time = (datetime)PositionGetInteger(POSITION_TIME);
      comment = PositionGetString(POSITION_COMMENT);
      return true;
   }

   return false;
}

double ParseRiskDistance(const string comment, const double fallback_from_sl, const double atr)
{
   int marker = StringFind(comment, "R=");
   if(marker >= 0)
   {
      string tail = StringSubstr(comment, marker + 2);
      int sep = StringFind(tail, "|");
      if(sep >= 0)
         tail = StringSubstr(tail, 0, sep);
      double parsed = StringToDouble(tail);
      if(parsed > 0.0)
         return parsed;
   }

   if(fallback_from_sl > 0.0)
      return fallback_from_sl;

   return SL_ATR * atr;
}

bool CloseStrategyPosition(const ulong ticket, const string reason)
{
   if(!PositionSelectByTicket(ticket))
      return false;

   long type = PositionGetInteger(POSITION_TYPE);
   double volume = PositionGetDouble(POSITION_VOLUME);
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double price = (type == POSITION_TYPE_BUY) ? bid : ask;

   bool sent = g_trade.PositionClose(ticket);
   int ret = (int)g_trade.ResultRetcode();
   bool ok = sent && (ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_DONE_PARTIAL);

   LogEvent(ok ? "POSITION_CLOSE" : "POSITION_CLOSE_FAIL",
            reason,
            (type == POSITION_TYPE_BUY) ? "BUY" : "SELL",
            volume,
            price,
            sl,
            tp,
            StringFormat("ret=%d", ret));

   return ok;
}

bool OpenTrade(const bool is_buy, const double atr, const datetime signal_bar)
{
   double bid = 0.0;
   double ask = 0.0;
   if(!GetCurrentBidAsk(bid, ask))
      return false;

   double entry = is_buy ? ask : bid;
   double sl_distance = SL_ATR * atr;
   double tp_distance = TP_ATR * atr;

   if(sl_distance <= 0.0 || tp_distance <= 0.0)
      return false;

   double volume = CalculateVolume(sl_distance);
   if(volume <= 0.0)
   {
      LogEvent("ENTRY_SKIP", "VolumeZero", is_buy ? "BUY" : "SELL", 0.0, entry, 0.0, 0.0, "risk sizing");
      return false;
   }

   double sl = is_buy ? (entry - sl_distance) : (entry + sl_distance);
   double tp = is_buy ? (entry + tp_distance) : (entry - tp_distance);
   sl = NormalizePrice(sl);
   tp = NormalizePrice(tp);

   string comment = "RB|R=" + DoubleToString(sl_distance, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));

   bool sent = false;
   if(is_buy)
      sent = g_trade.Buy(volume, _Symbol, 0.0, sl, tp, comment);
   else
      sent = g_trade.Sell(volume, _Symbol, 0.0, sl, tp, comment);

   int ret = (int)g_trade.ResultRetcode();
   bool ok = sent && (ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_DONE_PARTIAL || ret == TRADE_RETCODE_PLACED);

   LogEvent(ok ? "ENTRY" : "ENTRY_FAIL",
            is_buy ? "BreakoutLong" : "BreakoutShort",
            is_buy ? "BUY" : "SELL",
            volume,
            entry,
            sl,
            tp,
            StringFormat("ret=%d", ret));

   if(ok)
      SaveLastTradeBar(signal_bar);

   return ok;
}

void InitCalendar()
{
   g_calendar_enabled = false;
   g_calendar_change_id = 0;

   if(!UseNewsFilter)
      return;

   MqlCalendarValue values[];
   ResetLastError();
   CalendarValueLast(g_calendar_change_id, values, NULL, NULL);
   int err = GetLastError();

   if(err == 0 || err == 5400 || err == 5401 || err == 5402)
   {
      g_calendar_enabled = true;
      return;
   }

   PrintFormat("Economic calendar init failed (err=%d). News filter disabled.", err);
}

void PollCalendarDeltas(const datetime now)
{
   if(!g_calendar_enabled)
      return;

   if(now - g_last_calendar_poll < NEWS_POLL_SECONDS)
      return;

   g_last_calendar_poll = now;

   MqlCalendarValue updates[];
   ResetLastError();
   CalendarValueLast(g_calendar_change_id, updates, NULL, NULL);
   int err = GetLastError();

   if(err != 0 && err != 5400 && err != 5401 && err != 5402)
      PrintFormat("Calendar delta poll warning (err=%d)", err);
}

bool HasHighImpactEventInWindow(const datetime now)
{
   datetime from_time = now - (NewsBlockBeforeMin * 60);
   datetime to_time = now + (NewsBlockAfterMin * 60);
   int currencies = ArraySize(g_news_currencies);

   for(int i = 0; i < currencies; i++)
   {
      string currency = g_news_currencies[i];
      if(!IsCurrencySelected(currency))
         continue;

      MqlCalendarValue values[];
      ResetLastError();
      int total = CalendarValueHistory(values, from_time, to_time, NULL, currency);
      int err = GetLastError();

      if(total <= 0)
      {
         if(err != 0 && err != 5400 && err != 5401 && err != 5402)
            PrintFormat("Calendar history warning for %s (err=%d)", currency, err);
         continue;
      }

      for(int j = 0; j < total; j++)
      {
         MqlCalendarEvent event_data;
         if(!CalendarEventById(values[j].event_id, event_data))
            continue;

         if(event_data.importance == CALENDAR_IMPORTANCE_HIGH)
            return true;
      }
   }

   return false;
}

bool IsNewsBlocked(const datetime now)
{
   if(!UseNewsFilter || !g_calendar_enabled)
      return false;

   if(now - g_last_news_eval < NEWS_POLL_SECONDS)
      return g_news_blocked_cache;

   PollCalendarDeltas(now);
   g_news_blocked_cache = HasHighImpactEventInWindow(now);
   g_last_news_eval = now;
   return g_news_blocked_cache;
}

void ManageOpenPosition(const datetime now)
{
   ulong ticket = 0;
   long type = -1;
   double open_price = 0.0;
   double sl = 0.0;
   double tp = 0.0;
   double volume = 0.0;
   datetime open_time = 0;
   string comment = "";

   if(!GetStrategyPosition(ticket, type, open_price, sl, tp, volume, open_time, comment))
      return;

   if(IsFridayFlatTime(now))
   {
      CloseStrategyPosition(ticket, "FridayFlat");
      return;
   }

   if(g_consecutive_emergency_spread >= 3)
   {
      CloseStrategyPosition(ticket, "EmergencySpread");
      return;
   }

   int tf_seconds = PeriodSeconds(SignalTF);
   if(tf_seconds > 0 && MaxBarsInTrade > 0)
   {
      int bars_live = (int)((now - open_time) / tf_seconds);
      if(bars_live >= MaxBarsInTrade)
      {
         CloseStrategyPosition(ticket, "TimeStop");
         return;
      }
   }

   double atr = 0.0;
   if(!ReadBufferValue(g_atr_handle, 0, 1, atr) || atr <= 0.0)
      return;

   double bid = 0.0;
   double ask = 0.0;
   if(!GetCurrentBidAsk(bid, ask))
      return;

   bool is_buy = (type == POSITION_TYPE_BUY);
   double current_price = is_buy ? bid : ask;
   double move = is_buy ? (current_price - open_price) : (open_price - current_price);
   double fallback_risk = (sl > 0.0) ? MathAbs(open_price - sl) : 0.0;
   double initial_risk = ParseRiskDistance(comment, fallback_risk, atr);

   if(initial_risk <= 0.0)
      return;

   double r_multiple = move / initial_risk;
   double new_sl = sl;
   bool should_modify = false;

   if(r_multiple >= BE_Trigger_R)
   {
      double be_sl = NormalizePrice(open_price);
      if(is_buy)
      {
         if(sl == 0.0 || sl < be_sl)
         {
            new_sl = be_sl;
            should_modify = true;
         }
      }
      else
      {
         if(sl == 0.0 || sl > be_sl)
         {
            new_sl = be_sl;
            should_modify = true;
         }
      }
   }

   if(r_multiple >= TrailStart_R)
   {
      double trail_dist = TrailATR * atr;
      double trail_sl = is_buy ? (current_price - trail_dist) : (current_price + trail_dist);
      trail_sl = NormalizePrice(trail_sl);

      if(is_buy)
      {
         if((new_sl == 0.0 || trail_sl > new_sl) && trail_sl < current_price)
         {
            new_sl = trail_sl;
            should_modify = true;
         }
      }
      else
      {
         if((new_sl == 0.0 || trail_sl < new_sl) && trail_sl > current_price)
         {
            new_sl = trail_sl;
            should_modify = true;
         }
      }
   }

   if(!should_modify)
      return;

   bool modified = g_trade.PositionModify(ticket, new_sl, tp);
   int ret = (int)g_trade.ResultRetcode();
   bool ok = modified && (ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_DONE_PARTIAL);

   LogEvent(ok ? "SL_UPDATE" : "SL_UPDATE_FAIL",
            "RiskManagement",
            is_buy ? "BUY" : "SELL",
            volume,
            current_price,
            new_sl,
            tp,
            StringFormat("ret=%d;R=%.2f", ret, r_multiple));
}

void TryOpenEntry(const datetime now, const datetime signal_bar, const bool is_new_signal_bar)
{
   if(signal_bar <= 0)
   {
      RecordReject(REJECT_SIGNAL_BAR_UNAVAILABLE);
      return;
   }

   ENUM_ENTRY_TRIGGER_MODE trigger_mode = GetEffectiveEntryTriggerMode();

   if((trigger_mode == ENTRY_TRIGGER_BAR_OPEN || trigger_mode == ENTRY_TRIGGER_BAR_CLOSE) &&
      !is_new_signal_bar)
   {
      RecordReject(REJECT_TRIGGER_MODE_WAIT);
      return;
   }

   g_gate_stats.attempts++;

   if(CountStrategyPositions() > 0)
   {
      RecordReject(REJECT_POSITION_OPEN);
      return;
   }

   if(!CanTradeThisBar(signal_bar))
   {
      RecordReject(REJECT_ALREADY_TRADED_BAR);
      return;
   }

   int tf_seconds = PeriodSeconds(SignalTF);
   if(tf_seconds > 0 && g_last_exit_bar > 0)
   {
      int bars_since_exit = (int)((signal_bar - g_last_exit_bar) / tf_seconds);
      int cooldown_bars = g_last_exit_was_loss ? CooldownBarsAfterLoss : CooldownBarsAfterWin;
      if(cooldown_bars > 0 && bars_since_exit < cooldown_bars)
      {
         RecordReject(REJECT_COOLDOWN);
         return;
      }
   }

   if(!IsWithinSession(now))
   {
      RecordReject(REJECT_SESSION);
      return;
   }

   if(IsFridayFlatTime(now))
   {
      RecordReject(REJECT_FRIDAY_FLAT);
      return;
   }

   if(GetSpreadPoints() > MaxSpreadPoints)
   {
      RecordReject(REJECT_SPREAD);
      LogEvent("ENTRY_SKIP", "SpreadGuard", "-", 0.0, 0.0, 0.0, 0.0, "spread too high");
      return;
   }

   if(IsNewsBlocked(now))
   {
      RecordReject(REJECT_NEWS);
      LogEvent("ENTRY_SKIP", "NewsBlock", "-", 0.0, 0.0, 0.0, 0.0, "high-impact event window");
      return;
   }

   double atr = 0.0;
   double adx = 0.0;
   double ema_fast = 0.0;
   double ema_slow = 0.0;
   double donchian_high = 0.0;
   double donchian_low = 0.0;

   if(!ReadBufferValue(g_atr_handle, 0, 1, atr) || atr <= 0.0)
   {
      RecordReject(REJECT_ATR_INVALID);
      return;
   }
   if(!ReadBufferValue(g_adx_handle, 0, 1, adx) || adx < AdxMin)
   {
      RecordReject(REJECT_ADX_LOW);
      return;
   }
   if(!ReadBufferValue(g_ema_fast_handle, 0, 1, ema_fast))
   {
      RecordReject(REJECT_TREND_INVALID);
      return;
   }
   if(!ReadBufferValue(g_ema_slow_handle, 0, 1, ema_slow))
   {
      RecordReject(REJECT_TREND_INVALID);
      return;
   }
   if(!GetDonchianLevels(donchian_high, donchian_low))
   {
      RecordReject(REJECT_DONCHIAN_INVALID);
      return;
   }

   bool allow_long = (ema_fast > ema_slow);
   bool allow_short = (ema_fast < ema_slow);
   if(!allow_long && !allow_short)
   {
      RecordReject(REJECT_TREND_INVALID);
      return;
   }

   if(UseTrendSlopeFilter)
   {
      double trend_slope = MathAbs(ema_fast - ema_slow) / atr;
      if(trend_slope < MinTrendSlopeAtr)
      {
         RecordReject(REJECT_TREND_SLOPE);
         return;
      }
   }

   double long_trigger = donchian_high + (BreakoutBufferATR * atr);
   double short_trigger = donchian_low - (BreakoutBufferATR * atr);
   double long_eval_price = 0.0;
   double short_eval_price = 0.0;
   double prev_long_eval_price = 0.0;
   double prev_short_eval_price = 0.0;
   bool has_prev_eval = false;

   if(trigger_mode == ENTRY_TRIGGER_BAR_CLOSE)
   {
      double closes[];
      int copied = CopyClose(_Symbol, SignalTF, 1, 2, closes);
      if(copied != 2 || !MathIsValidNumber(closes[0]) || closes[0] <= 0.0 || !MathIsValidNumber(closes[1]) || closes[1] <= 0.0)
      {
         RecordReject(REJECT_QUOTES_INVALID);
         return;
      }
      long_eval_price = closes[0];
      short_eval_price = closes[0];
      prev_long_eval_price = closes[1];
      prev_short_eval_price = closes[1];
      has_prev_eval = true;
   }
   else
   {
      double bid = 0.0;
      double ask = 0.0;
      if(!GetCurrentBidAsk(bid, ask))
      {
         RecordReject(REJECT_QUOTES_INVALID);
         return;
      }
      long_eval_price = ask;
      short_eval_price = bid;

      if(g_prev_quotes_ready)
      {
         prev_long_eval_price = g_prev_ask;
         prev_short_eval_price = g_prev_bid;
         has_prev_eval = true;
      }
   }

   double reference_price = (long_eval_price + short_eval_price) / 2.0;
   if(reference_price <= 0.0)
   {
      RecordReject(REJECT_QUOTES_INVALID);
      return;
   }

   if(MaxAtrToPricePct > 0.0)
   {
      double atr_pct = (atr / reference_price) * 100.0;
      if(atr_pct > MaxAtrToPricePct)
      {
         RecordReject(REJECT_VOLATILITY);
         return;
      }
   }

   double atr_percentile = 0.0;
   if(!IsAtrPercentileAllowed(atr, atr_percentile))
   {
      RecordReject(REJECT_VOL_PCTL);
      return;
   }

   g_gate_stats.signals_passed++;

   bool long_breakout_raw = (allow_long && long_eval_price > long_trigger);
   bool short_breakout_raw = (allow_short && short_eval_price < short_trigger);
   bool long_breakout = long_breakout_raw;
   bool short_breakout = short_breakout_raw;
   bool cross_blocked = false;
   bool excess_blocked = false;
   bool reentry_blocked = false;

   if(RequireCrossingSignal)
   {
      if(!has_prev_eval)
      {
         RecordReject(REJECT_NO_CROSS);
         return;
      }

      if(long_breakout)
      {
         if(prev_long_eval_price > long_trigger)
         {
            long_breakout = false;
            cross_blocked = true;
         }
      }

      if(short_breakout)
      {
         if(prev_short_eval_price < short_trigger)
         {
            short_breakout = false;
            cross_blocked = true;
         }
      }
   }

   double min_breakout_excess = MathMax(0.0, MinBreakoutExcessAtr) * atr;
   if(min_breakout_excess > 0.0)
   {
      if(long_breakout)
      {
         double long_excess = long_eval_price - long_trigger;
         if(long_excess < min_breakout_excess)
         {
            long_breakout = false;
            excess_blocked = true;
         }
      }

      if(short_breakout)
      {
         double short_excess = short_trigger - short_eval_price;
         if(short_excess < min_breakout_excess)
         {
            short_breakout = false;
            excess_blocked = true;
         }
      }
   }

   if(long_breakout && IsReentryLocked(1, signal_bar, atr, reference_price))
   {
      long_breakout = false;
      reentry_blocked = true;
   }

   if(short_breakout && IsReentryLocked(-1, signal_bar, atr, reference_price))
   {
      short_breakout = false;
      reentry_blocked = true;
   }

   if(long_breakout)
   {
      if(OpenTrade(true, atr, signal_bar))
         g_gate_stats.entries++;
      return;
   }

   if(short_breakout)
   {
      if(OpenTrade(false, atr, signal_bar))
         g_gate_stats.entries++;
      return;
   }

   if(excess_blocked)
   {
      RecordReject(REJECT_BREAKOUT_EXCESS);
      return;
   }

   if(reentry_blocked)
   {
      RecordReject(REJECT_REENTRY_LOCK);
      return;
   }

   if(cross_blocked || (RequireCrossingSignal && (long_breakout_raw || short_breakout_raw)))
   {
      RecordReject(REJECT_NO_CROSS);
      return;
   }

   RecordReject(REJECT_BREAKOUT_NOT_REACHED);
}

int OnInit()
{
   string symbol_upper = ToUpperCopy(_Symbol);
   if(StringFind(symbol_upper, "XAUUSD") < 0)
      Print("Warning: This EA is designed for XAUUSD. Current symbol may not match planned behavior.");

   g_trade.SetExpertMagicNumber(EA_MAGIC);
   g_trade.SetDeviationInPoints(30);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   ParseNewsCurrencies();
   InitLastTradeBarState();
   ResetGateStats();
   g_diag_bar_counter = 0;
   g_last_exit_bar = 0;
   g_last_exit_was_loss = false;
   g_last_exit_trade_direction = 0;
   g_last_exit_price = 0.0;
   g_prev_bid = 0.0;
   g_prev_ask = 0.0;
   g_prev_quotes_ready = false;
   ResetRegimeStats(g_regime_early);
   ResetRegimeStats(g_regime_late);
   InitTradeLog();

   if(!InitIndicators())
      return INIT_FAILED;

   InitCalendar();

   LogEvent("INIT",
            "EAStart",
            "-",
            0.0,
            0.0,
            0.0,
            0.0,
            StringFormat("SignalTF=%s TrendTF=%s EntryMode=%d EffectiveMode=%d MaxAtrPct=%.2f CooldownLoss=%d SlopeFilter=%d VolPctlFilter=%d ReentryLock=%d",
                         EnumToString(SignalTF),
                         EnumToString(TrendTF),
                         (int)EntryTriggerMode,
                         (int)GetEffectiveEntryTriggerMode(),
                         MaxAtrToPricePct,
                         CooldownBarsAfterLoss,
                         UseTrendSlopeFilter ? 1 : 0,
                         UseVolatilityPercentileFilter ? 1 : 0,
                         UseReentryPullbackLock ? 1 : 0));

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EmitGateDiagnostics("deinit", true);
   EmitRegimeDiagnostics("deinit", true);
   LogEvent("DEINIT", IntegerToString(reason), "-", 0.0, 0.0, 0.0, 0.0, "EA stop");

   ReleaseIndicators();

   if(g_log_handle != INVALID_HANDLE)
   {
      FileClose(g_log_handle);
      g_log_handle = INVALID_HANDLE;
   }
}

void OnTick()
{
   datetime now = TimeTradeServer();
   if(now <= 0)
      now = TimeCurrent();

   datetime signal_bar = 0;
   bool is_new_signal_bar = IsNewSignalBar(signal_bar);

   if(is_new_signal_bar)
   {
      if(GetSpreadPoints() > (2 * MaxSpreadPoints))
         g_consecutive_emergency_spread++;
      else
         g_consecutive_emergency_spread = 0;
   }

   ManageOpenPosition(now);

   bool has_position = (CountStrategyPositions() > 0);
   if(has_position)
   {
      if(EnableGateDiagnostics && is_new_signal_bar)
         RecordReject(REJECT_POSITION_OPEN);
   }
   else
   {
      ENUM_ENTRY_TRIGGER_MODE trigger_mode = GetEffectiveEntryTriggerMode();
      bool should_eval_entry = (trigger_mode == ENTRY_TRIGGER_INTRABAR || is_new_signal_bar);
      if(should_eval_entry)
         TryOpenEntry(now, signal_bar, is_new_signal_bar);
   }

   MaybeEmitPeriodicGateDiagnostics(is_new_signal_bar);

   double end_bid = 0.0;
   double end_ask = 0.0;
   if(GetCurrentBidAsk(end_bid, end_ask))
   {
      g_prev_bid = end_bid;
      g_prev_ask = end_ask;
      g_prev_quotes_ready = true;
   }
}

double OnTester()
{
   double pf = TesterStatistics(STAT_PROFIT_FACTOR);
   double dd = TesterStatistics(STAT_BALANCE_DDREL_PERCENT);
   double trades = TesterStatistics(STAT_TRADES);

   if(pf <= 0.0 || trades <= 0.0)
      return -1000.0;

   if(dd > 15.0)
      return pf - (dd - 15.0) - 10.0;

   if(MinTradesForScore > 0 && trades < (double)MinTradesForScore)
   {
      double ratio = trades / (double)MinTradesForScore;
      if(trades <= 10.0)
         return -1000.0 + ratio;

      // Penalize under-sampled runs during calibration while still ranking them below fully sampled sets.
      return (pf * ratio) - 10.0;
   }

   return pf;
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong deal_ticket = trans.deal;
   if(deal_ticket == 0 || !HistoryDealSelect(deal_ticket))
      return;

   string deal_symbol = HistoryDealGetString(deal_ticket, DEAL_SYMBOL);
   if(deal_symbol != _Symbol)
      return;

   long magic = HistoryDealGetInteger(deal_ticket, DEAL_MAGIC);
   if(magic != EA_MAGIC)
      return;

   long deal_type = HistoryDealGetInteger(deal_ticket, DEAL_TYPE);
   long deal_entry = HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
   double volume = HistoryDealGetDouble(deal_ticket, DEAL_VOLUME);
   double price = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
   double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);

   if(deal_entry == DEAL_ENTRY_OUT || deal_entry == DEAL_ENTRY_OUT_BY)
   {
      datetime bars[];
      ArraySetAsSeries(bars, true);
      datetime exit_bar = 0;
      if(CopyTime(_Symbol, SignalTF, 0, 1, bars) == 1)
         exit_bar = bars[0];
      if(exit_bar <= 0)
         exit_bar = (datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME);

      g_last_exit_bar = exit_bar;
      g_last_exit_was_loss = (profit <= 0.0);
      g_last_exit_price = price;
      g_last_exit_trade_direction = 0;

      if(deal_type == DEAL_TYPE_SELL)
         g_last_exit_trade_direction = 1;
      else if(deal_type == DEAL_TYPE_BUY)
         g_last_exit_trade_direction = -1;

      datetime deal_time = (datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME);
      UpdateRegimeStats(deal_time, profit);
   }

   string side = "OTHER";
   if(deal_type == DEAL_TYPE_BUY)
      side = "BUY";
   else if(deal_type == DEAL_TYPE_SELL)
      side = "SELL";

   string evt = (deal_entry == DEAL_ENTRY_IN) ? "DEAL_IN" : "DEAL_OUT";

   LogEvent(evt,
            StringFormat("profit=%.2f", profit),
            side,
            volume,
            price,
            0.0,
            0.0,
            StringFormat("deal=%I64d", deal_ticket));
}
