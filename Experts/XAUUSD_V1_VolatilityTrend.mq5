#property copyright "SMINDS"
#property version   "2.00"
#property strict
#property description "XAUUSD V1 volatility trend production upgrade (H4 trend + H1 pullback/continuation)"

#include <Trade/Trade.mqh>

#define DEFAULT_NEWS_CURRENCY "USD"
#define NEWS_POLL_SECONDS 60
#define PARTIAL_MIN_REMAIN_STEP 2

// === Original V1 Inputs ===
input int InpFastEMA_H4 = 50;
input int InpSlowEMA_H4 = 200;
input int InpRSIPeriod = 14;
input int InpATRPeriod = 14;
input double InpRiskPercent = 0.75;
input double InpATR_SL_Mult = 2.2;
input double InpATR_Trail_Mult = 1.8;
input int InpMinSL_Points = 250;
input int InpMaxSL_Points = 600;
input int InpMaxSpread = 30;
input double InpMaxDailyLossPercent = 2.0;
input bool InpUseTimeFilter = true;
input int InpStartHour = 7;
input int InpEndHour = 18;

// === Production Controls ===
input int InpMagic = 26022451;
input bool InpOnePositionOnly = true;

input bool InpUseRegimeFilter = true;
input int InpRegimeAdxPeriod = 14;
input double InpRegimeAdxMin = 20.0;
input int InpRegimeAtrLookback = 200;
input double InpRegimeAtrPctMin = 25.0;
input double InpRegimeAtrPctMax = 85.0;
input bool InpUseTrendSlopeFilter = true;
input int InpTrendSlopeBars = 3;
input double InpTrendSlopeMinAtr = 0.08;

input bool InpUsePullbackEntry = true;
input bool InpUseBreakoutContinuation = true;
input double InpBreakoutBufferATR = 0.15;
input bool InpRequireH1CloseConfirmation = true;

input bool InpUseFixedRRTarget = true;
input double InpTP_R_Mult = 2.2;
input bool InpUsePartialClose = true;
input double InpPartialAtR = 1.3;
input double InpPartialPct = 40.0;
input bool InpUseTrailingAfterBE = true;
input double InpBreakEvenAtR = 1.0;

input bool InpUseCooldownAfterLoss = true;
input int InpCooldownBarsAfterLoss = 3;
input bool InpUseMaxBarsInTrade = true;
input int InpMaxBarsInTrade = 36;

input bool InpUseNewsFilter = false;
input int InpMinTradesForScore = 20;

CTrade g_trade;

int g_h4_fast_handle = INVALID_HANDLE;
int g_h4_slow_handle = INVALID_HANDLE;
int g_h1_rsi_handle = INVALID_HANDLE;
int g_h1_atr_handle = INVALID_HANDLE;
int g_h4_atr_handle = INVALID_HANDLE;
int g_h4_adx_handle = INVALID_HANDLE;
int g_h1_pullback_ema_handle = INVALID_HANDLE;

datetime g_last_signal_bar = 0;
string g_last_trade_bar_key = "";
double g_last_trade_bar = 0.0;
string g_last_loss_time_key = "";
double g_last_loss_close_time = 0.0;
string g_partial_done_ticket_key = "";
double g_partial_done_ticket = 0.0;

int g_log_handle = INVALID_HANDLE;
string g_log_file = "";

int g_day_code = -1;
double g_day_start_balance = 0.0;
double g_daily_realized_pnl = 0.0;
int g_consecutive_losses = 0;

datetime g_last_news_eval = 0;
bool g_news_blocked_cache = false;
ulong g_calendar_change_id = 0;
datetime g_last_calendar_poll = 0;
bool g_calendar_enabled = false;
string g_news_currencies[];

struct ExecStats
{
   ulong entry_attempts;
   ulong entry_success;
   ulong entry_fail;
   ulong close_attempts;
   ulong close_success;
   ulong modify_attempts;
   ulong modify_success;
   ulong partial_attempts;
   ulong partial_success;
};

ExecStats g_exec_stats;

string ToUpperCopy(string value)
{
   StringToUpper(value);
   return value;
}

int VolumeDigits(const double step)
{
   for(int digits = 0; digits <= 8; digits++)
   {
      double scaled = step * MathPow(10.0, digits);
      if(MathAbs(scaled - MathRound(scaled)) < 1e-8)
         return digits;
   }
   return 8;
}

void ResetExecStats()
{
   g_exec_stats.entry_attempts = 0;
   g_exec_stats.entry_success = 0;
   g_exec_stats.entry_fail = 0;
   g_exec_stats.close_attempts = 0;
   g_exec_stats.close_success = 0;
   g_exec_stats.modify_attempts = 0;
   g_exec_stats.modify_success = 0;
   g_exec_stats.partial_attempts = 0;
   g_exec_stats.partial_success = 0;
}

void ParseNewsCurrencies()
{
   ArrayResize(g_news_currencies, 1);
   g_news_currencies[0] = DEFAULT_NEWS_CURRENCY;
}

int GetDayCode(const datetime when_time)
{
   MqlDateTime dt;
   TimeToStruct(when_time, dt);
   return (dt.year * 10000) + (dt.mon * 100) + dt.day;
}

void EnsureDailyState(const datetime now)
{
   int code = GetDayCode(now);
   if(code == g_day_code)
      return;

   g_day_code = code;
   g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_daily_realized_pnl = 0.0;
   g_consecutive_losses = 0;
}

bool InitTradeLog()
{
   string stamp = TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS);
   StringReplace(stamp, ":", "-");
   StringReplace(stamp, ".", "-");
   StringReplace(stamp, " ", "_");

   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   g_log_file = StringFormat("XAUUSD_V1_VolatilityTrend_%I64d_%s.csv", login, stamp);
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

void EmitExecSummary()
{
   string summary = StringFormat("entry_attempts=%I64u;entry_success=%I64u;entry_fail=%I64u;close_attempts=%I64u;close_success=%I64u;modify_attempts=%I64u;modify_success=%I64u;partial_attempts=%I64u;partial_success=%I64u",
                                 g_exec_stats.entry_attempts,
                                 g_exec_stats.entry_success,
                                 g_exec_stats.entry_fail,
                                 g_exec_stats.close_attempts,
                                 g_exec_stats.close_success,
                                 g_exec_stats.modify_attempts,
                                 g_exec_stats.modify_success,
                                 g_exec_stats.partial_attempts,
                                 g_exec_stats.partial_success);
   LogEvent("RUN_STATS", "ExecStats", "-", 0.0, 0.0, 0.0, 0.0, summary);
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
   if(min_volume <= 0.0 || max_volume <= 0.0 || volume_step <= 0.0)
      return 0.0;

   double clipped = MathMax(min_volume, MathMin(max_volume, raw_volume));
   double stepped = MathFloor(clipped / volume_step) * volume_step;
   int digits = VolumeDigits(volume_step);
   return NormalizeDouble(stepped, digits);
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

bool ReadBufferValue(const int handle, const int buffer, const int shift, double &value)
{
   double data[];
   int copied = CopyBuffer(handle, buffer, shift, 1, data);
   if(copied != 1)
      return false;

   value = data[0];
   return MathIsValidNumber(value);
}

bool InitIndicators()
{
   g_h4_fast_handle = iMA(_Symbol, PERIOD_H4, InpFastEMA_H4, 0, MODE_EMA, PRICE_CLOSE);
   g_h4_slow_handle = iMA(_Symbol, PERIOD_H4, InpSlowEMA_H4, 0, MODE_EMA, PRICE_CLOSE);
   g_h1_pullback_ema_handle = iMA(_Symbol, PERIOD_H1, InpFastEMA_H4, 0, MODE_EMA, PRICE_CLOSE);
   g_h1_rsi_handle = iRSI(_Symbol, PERIOD_H1, InpRSIPeriod, PRICE_CLOSE);
   g_h1_atr_handle = iATR(_Symbol, PERIOD_H1, InpATRPeriod);
   g_h4_atr_handle = iATR(_Symbol, PERIOD_H4, InpATRPeriod);
   g_h4_adx_handle = iADX(_Symbol, PERIOD_H4, InpRegimeAdxPeriod);

   if(g_h4_fast_handle == INVALID_HANDLE ||
      g_h4_slow_handle == INVALID_HANDLE ||
      g_h1_pullback_ema_handle == INVALID_HANDLE ||
      g_h1_rsi_handle == INVALID_HANDLE ||
      g_h1_atr_handle == INVALID_HANDLE ||
      g_h4_atr_handle == INVALID_HANDLE ||
      g_h4_adx_handle == INVALID_HANDLE)
   {
      Print("Failed to initialize one or more indicator handles.");
      return false;
   }

   return true;
}

void ReleaseIndicators()
{
   if(g_h4_fast_handle != INVALID_HANDLE)
      IndicatorRelease(g_h4_fast_handle);
   if(g_h4_slow_handle != INVALID_HANDLE)
      IndicatorRelease(g_h4_slow_handle);
   if(g_h1_pullback_ema_handle != INVALID_HANDLE)
      IndicatorRelease(g_h1_pullback_ema_handle);
   if(g_h1_rsi_handle != INVALID_HANDLE)
      IndicatorRelease(g_h1_rsi_handle);
   if(g_h1_atr_handle != INVALID_HANDLE)
      IndicatorRelease(g_h1_atr_handle);
   if(g_h4_atr_handle != INVALID_HANDLE)
      IndicatorRelease(g_h4_atr_handle);
   if(g_h4_adx_handle != INVALID_HANDLE)
      IndicatorRelease(g_h4_adx_handle);
}

void InitPersistentState()
{
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   g_last_trade_bar_key = StringFormat("V1_LAST_BAR_%I64d_%s", login, _Symbol);
   g_last_loss_time_key = StringFormat("V1_LAST_LOSS_%I64d_%s", login, _Symbol);
   g_partial_done_ticket_key = StringFormat("V1_PARTIAL_%I64d_%s", login, _Symbol);

   g_last_trade_bar = GlobalVariableCheck(g_last_trade_bar_key) ? GlobalVariableGet(g_last_trade_bar_key) : 0.0;
   g_last_loss_close_time = GlobalVariableCheck(g_last_loss_time_key) ? GlobalVariableGet(g_last_loss_time_key) : 0.0;
   g_partial_done_ticket = GlobalVariableCheck(g_partial_done_ticket_key) ? GlobalVariableGet(g_partial_done_ticket_key) : 0.0;
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

void SaveLastLossCloseTime(const datetime when_time)
{
   g_last_loss_close_time = (double)when_time;
   GlobalVariableSet(g_last_loss_time_key, g_last_loss_close_time);
}

bool IsCooldownBlocked(const datetime bar_time)
{
   if(!InpUseCooldownAfterLoss || InpCooldownBarsAfterLoss <= 0)
      return false;
   if(g_last_loss_close_time <= 0.0)
      return false;

   int tf_seconds = PeriodSeconds(PERIOD_H1);
   if(tf_seconds <= 0)
      return false;

   int bars_since_loss = (int)((bar_time - (datetime)g_last_loss_close_time) / tf_seconds);
   return (bars_since_loss >= 0 && bars_since_loss < InpCooldownBarsAfterLoss);
}

bool IsPartialDoneForTicket(const ulong ticket)
{
   if(ticket == 0)
      return false;
   return (MathAbs(g_partial_done_ticket - (double)ticket) < 0.5);
}

void MarkPartialDoneTicket(const ulong ticket)
{
   g_partial_done_ticket = (double)ticket;
   GlobalVariableSet(g_partial_done_ticket_key, g_partial_done_ticket);
}

void ClearPartialDoneTicket()
{
   g_partial_done_ticket = 0.0;
   GlobalVariableSet(g_partial_done_ticket_key, g_partial_done_ticket);
}

bool IsNewSignalBar(datetime &bar_time)
{
   datetime bars[];
   ArraySetAsSeries(bars, true);

   if(CopyTime(_Symbol, PERIOD_H1, 0, 2, bars) < 2)
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

bool IsWithinTradingHours(const datetime now)
{
   if(!InpUseTimeFilter)
      return true;

   MqlDateTime dt;
   TimeToStruct(now, dt);
   int now_minutes = dt.hour * 60 + dt.min;
   int start_hour = MathMax(0, MathMin(24, InpStartHour));
   int end_hour = MathMax(0, MathMin(24, InpEndHour));
   int start_minutes = start_hour * 60;
   int end_minutes = end_hour * 60;

   if(start_minutes == end_minutes)
      return true;

   if(start_minutes < end_minutes)
      return (now_minutes >= start_minutes && now_minutes < end_minutes);

   return (now_minutes >= start_minutes || now_minutes < end_minutes);
}

bool IsRolloverHour(const datetime now)
{
   MqlDateTime dt;
   TimeToStruct(now, dt);
   return (dt.hour == 23);
}

bool IsFridayFlatTime(const datetime now)
{
   MqlDateTime dt;
   TimeToStruct(now, dt);

   if(dt.day_of_week != 5)
      return false;

   if(dt.hour > 21)
      return true;
   if(dt.hour < 21)
      return false;
   return (dt.min >= 45);
}

int CountStrategyPositions()
{
   int count = 0;
   int total = PositionsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      count++;
   }
   return count;
}

bool HasAnyOpenPosition()
{
   return (PositionsTotal() > 0);
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
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != InpMagic)
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

double ParseRiskDistance(const string comment, const double fallback)
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
   return fallback;
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

   g_exec_stats.close_attempts++;
   bool sent = g_trade.PositionClose(ticket);
   int ret = (int)g_trade.ResultRetcode();
   bool ok = sent && (ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_DONE_PARTIAL);
   if(ok)
      g_exec_stats.close_success++;

   LogEvent(ok ? "POSITION_CLOSE" : "POSITION_CLOSE_FAIL",
            reason,
            (type == POSITION_TYPE_BUY) ? "BUY" : "SELL",
            volume,
            price,
            sl,
            tp,
            StringFormat("ret=%d;desc=%s", ret, g_trade.ResultRetcodeDescription()));

   return ok;
}

bool InitCalendar()
{
   g_calendar_enabled = false;
   g_calendar_change_id = 0;

   if(!InpUseNewsFilter)
      return true;

   MqlCalendarValue values[];
   ResetLastError();
   CalendarValueLast(g_calendar_change_id, values, NULL, NULL);
   int err = GetLastError();

   if(err == 0 || err == 5400 || err == 5401 || err == 5402)
   {
      g_calendar_enabled = true;
      return true;
   }

   PrintFormat("Economic calendar init failed (err=%d). News filter disabled.", err);
   return false;
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
   datetime from_time = now - (30 * 60);
   datetime to_time = now + (30 * 60);

   int currencies = ArraySize(g_news_currencies);
   for(int i = 0; i < currencies; i++)
   {
      string currency = g_news_currencies[i];
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
   if(!InpUseNewsFilter || !g_calendar_enabled)
      return false;

   if(now - g_last_news_eval < NEWS_POLL_SECONDS)
      return g_news_blocked_cache;

   PollCalendarDeltas(now);
   g_news_blocked_cache = HasHighImpactEventInWindow(now);
   g_last_news_eval = now;
   return g_news_blocked_cache;
}

double ComputeAtrPercentileH4(const double current_atr)
{
   if(current_atr <= 0.0 || InpRegimeAtrLookback < 30)
      return -1.0;

   double atr_values[];
   int copied = CopyBuffer(g_h4_atr_handle, 0, 2, InpRegimeAtrLookback, atr_values);
   if(copied < 30)
      return -1.0;

   int below_eq = 0;
   int valid = 0;
   for(int i = 0; i < copied; i++)
   {
      double v = atr_values[i];
      if(!MathIsValidNumber(v) || v <= 0.0)
         continue;
      valid++;
      if(v <= current_atr)
         below_eq++;
   }

   if(valid < 30)
      return -1.0;
   return (100.0 * (double)below_eq) / (double)valid;
}

bool IsMarketTradable(const datetime now, string &reason)
{
   reason = "";

   if(GetSpreadPoints() > InpMaxSpread)
   {
      reason = "SpreadGuard";
      return false;
   }

   if(IsRolloverHour(now))
   {
      reason = "RolloverHour";
      return false;
   }

   double atr_h4 = 0.0;
   if(!ReadBufferValue(g_h4_atr_handle, 0, 1, atr_h4) || atr_h4 <= 0.0)
   {
      reason = "ATR_H4_Invalid";
      return false;
   }

   int lookback = MathMax(30, InpRegimeAtrLookback);
   double atr_hist[];
   int copied = CopyBuffer(g_h4_atr_handle, 0, 1, lookback, atr_hist);
   if(copied < 30)
   {
      reason = "ATR_H4_History";
      return false;
   }

   double sum = 0.0;
   int valid = 0;
   for(int i = 0; i < copied; i++)
   {
      if(!MathIsValidNumber(atr_hist[i]) || atr_hist[i] <= 0.0)
         continue;
      sum += atr_hist[i];
      valid++;
   }
   if(valid < 30)
   {
      reason = "ATR_H4_Avg";
      return false;
   }

   double avg = sum / (double)valid;
   if(atr_h4 <= (avg * 0.8))
   {
      reason = "ATR_H4_TooLow";
      return false;
   }

   if(InpUseRegimeFilter)
   {
      double adx = 0.0;
      if(!ReadBufferValue(g_h4_adx_handle, 0, 1, adx) || adx < InpRegimeAdxMin)
      {
         reason = "RegimeADX";
         return false;
      }

      double pctl = ComputeAtrPercentileH4(atr_h4);
      if(pctl >= 0.0 && (pctl < InpRegimeAtrPctMin || pctl > InpRegimeAtrPctMax))
      {
         reason = "RegimeAtrPercentile";
         return false;
      }
   }

   return true;
}

int GetTrendDirection()
{
   double ema_fast = 0.0;
   double ema_slow = 0.0;
   if(!ReadBufferValue(g_h4_fast_handle, 0, 1, ema_fast))
      return 0;
   if(!ReadBufferValue(g_h4_slow_handle, 0, 1, ema_slow))
      return 0;

   double close_h4[];
   double open_h4[];
   if(CopyClose(_Symbol, PERIOD_H4, 1, 1, close_h4) != 1)
      return 0;
   if(CopyOpen(_Symbol, PERIOD_H4, 1, 1, open_h4) != 1)
      return 0;

   bool candle_bull = (close_h4[0] > open_h4[0]);
   bool candle_bear = (close_h4[0] < open_h4[0]);

   int trend = 0;
   if(close_h4[0] > ema_slow && ema_fast > ema_slow && candle_bull)
      trend = 1;
   else if(close_h4[0] < ema_slow && ema_fast < ema_slow && candle_bear)
      trend = -1;

   if(trend == 0 || !InpUseTrendSlopeFilter)
      return trend;

   int slope_bars = MathMax(1, InpTrendSlopeBars);
   double ema_past = 0.0;
   if(!ReadBufferValue(g_h4_fast_handle, 0, 1 + slope_bars, ema_past))
      return 0;

   double atr_h4 = 0.0;
   if(!ReadBufferValue(g_h4_atr_handle, 0, 1, atr_h4) || atr_h4 <= 0.0)
      return 0;

   double slope_atr = (ema_fast - ema_past) / atr_h4;
   if(trend > 0 && slope_atr < InpTrendSlopeMinAtr)
      return 0;
   if(trend < 0 && slope_atr > -InpTrendSlopeMinAtr)
      return 0;

   return trend;
}

bool CheckPullbackEntry(const int trend_dir, const double atr_h1)
{
   if(!InpUsePullbackEntry || atr_h1 <= 0.0)
      return false;

   double close1[];
   double open1[];
   if(CopyClose(_Symbol, PERIOD_H1, 1, 1, close1) != 1)
      return false;
   if(CopyOpen(_Symbol, PERIOD_H1, 1, 1, open1) != 1)
      return false;

   double pullback_ema = 0.0;
   double rsi = 0.0;
   if(!ReadBufferValue(g_h1_pullback_ema_handle, 0, 1, pullback_ema))
      return false;
   if(!ReadBufferValue(g_h1_rsi_handle, 0, 1, rsi))
      return false;

   double distance = MathAbs(close1[0] - pullback_ema);
   bool near_ema = (distance <= (0.5 * atr_h1));

   if(trend_dir > 0)
      return (near_ema && rsi >= 40.0 && rsi <= 50.0 && close1[0] > open1[0]);
   if(trend_dir < 0)
      return (near_ema && rsi >= 50.0 && rsi <= 60.0 && close1[0] < open1[0]);
   return false;
}

bool CheckBreakoutContinuation(const int trend_dir, const double atr_h1)
{
   if(!InpUseBreakoutContinuation || atr_h1 <= 0.0)
      return false;

   double close1[];
   double high2[];
   double low2[];
   double open1[];
   if(CopyClose(_Symbol, PERIOD_H1, 1, 1, close1) != 1)
      return false;
   if(CopyOpen(_Symbol, PERIOD_H1, 1, 1, open1) != 1)
      return false;
   if(CopyHigh(_Symbol, PERIOD_H1, 2, 1, high2) != 1)
      return false;
   if(CopyLow(_Symbol, PERIOD_H1, 2, 1, low2) != 1)
      return false;

   double rsi = 0.0;
   if(!ReadBufferValue(g_h1_rsi_handle, 0, 1, rsi))
      return false;

   double long_trigger = high2[0] + (InpBreakoutBufferATR * atr_h1);
   double short_trigger = low2[0] - (InpBreakoutBufferATR * atr_h1);

   if(trend_dir > 0)
   {
      if(InpRequireH1CloseConfirmation)
         return (close1[0] > long_trigger && close1[0] > open1[0] && rsi >= 50.0);

      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      return (ask > long_trigger && rsi >= 50.0);
   }
   if(trend_dir < 0)
   {
      if(InpRequireH1CloseConfirmation)
         return (close1[0] < short_trigger && close1[0] < open1[0] && rsi <= 50.0);

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      return (bid < short_trigger && rsi <= 50.0);
   }
   return false;
}

bool CheckEntrySignal(const int trend_dir, const double atr_h1)
{
   bool pullback_ok = CheckPullbackEntry(trend_dir, atr_h1);
   bool continuation_ok = CheckBreakoutContinuation(trend_dir, atr_h1);
   return (pullback_ok || continuation_ok);
}

int CalculateStopLossPoints(const double atr_h1)
{
   if(_Point <= 0.0)
      return InpMinSL_Points;

   double raw = (InpATR_SL_Mult * atr_h1) / _Point;
   int points = (int)MathRound(raw);
   if(points < InpMinSL_Points)
      points = InpMinSL_Points;
   if(points > InpMaxSL_Points)
      points = InpMaxSL_Points;
   if(points < 1)
      points = 1;
   return points;
}

double CalculateLotSize(const int stop_loss_points, const ENUM_ORDER_TYPE order_type, const double order_price)
{
   if(stop_loss_points <= 0 || _Point <= 0.0)
      return 0.0;

   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tick_size <= 0.0 || tick_value <= 0.0)
      return 0.0;

   double risk_amount = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPercent / 100.0);
   if(risk_amount <= 0.0)
      return 0.0;

   double stop_distance = (double)stop_loss_points * _Point;
   double ticks = stop_distance / tick_size;
   double loss_per_lot = ticks * tick_value;
   if(loss_per_lot <= 0.0)
      return 0.0;

   double volume = risk_amount / loss_per_lot;
   volume = NormalizeVolume(volume);
   if(volume <= 0.0)
      return 0.0;

   double min_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(min_volume <= 0.0 || step <= 0.0 || free_margin <= 0.0)
      return volume;

   for(double v = volume; v >= min_volume - 1e-8; v -= step)
   {
      double check = NormalizeVolume(v);
      if(check < min_volume - 1e-8)
         break;
      double margin = 0.0;
      if(!OrderCalcMargin(order_type, _Symbol, check, order_price, margin))
         continue;
      if(margin <= (free_margin * 0.95))
         return check;
   }

   return 0.0;
}

bool IsKillSwitchActive(const datetime now)
{
   EnsureDailyState(now);

   if(g_day_start_balance <= 0.0)
      return false;

   double loss_pct = 0.0;
   if(g_daily_realized_pnl < 0.0)
      loss_pct = (MathAbs(g_daily_realized_pnl) / g_day_start_balance) * 100.0;

   if(loss_pct >= InpMaxDailyLossPercent)
      return true;
   if(g_consecutive_losses >= 2)
      return true;
   return false;
}

bool OpenTrade(const bool is_buy, const double atr_h1, const datetime signal_bar)
{
   double bid = 0.0;
   double ask = 0.0;
   if(!GetCurrentBidAsk(bid, ask))
      return false;

   int stop_points = CalculateStopLossPoints(atr_h1);
   double stop_dist = (double)stop_points * _Point;
   if(stop_dist <= 0.0)
      return false;

   double entry = is_buy ? ask : bid;
   double sl = is_buy ? (entry - stop_dist) : (entry + stop_dist);
   double tp = 0.0;
   if(InpUseFixedRRTarget && InpTP_R_Mult > 0.0)
   {
      double tp_dist = InpTP_R_Mult * stop_dist;
      tp = is_buy ? (entry + tp_dist) : (entry - tp_dist);
   }

   sl = NormalizePrice(sl);
   tp = (tp > 0.0) ? NormalizePrice(tp) : 0.0;

   ENUM_ORDER_TYPE ord_type = is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double volume = CalculateLotSize(stop_points, ord_type, entry);
   if(volume <= 0.0)
   {
      LogEvent("ENTRY_SKIP", "VolumeZero", is_buy ? "BUY" : "SELL", 0.0, entry, sl, tp, "risk sizing");
      return false;
   }

   string comment = "V1|R=" + DoubleToString(stop_dist, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));

   g_exec_stats.entry_attempts++;
   bool sent = false;
   if(is_buy)
      sent = g_trade.Buy(volume, _Symbol, 0.0, sl, tp, comment);
   else
      sent = g_trade.Sell(volume, _Symbol, 0.0, sl, tp, comment);

   int ret = (int)g_trade.ResultRetcode();
   bool ok = sent && (ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_DONE_PARTIAL || ret == TRADE_RETCODE_PLACED);
   if(ok)
      g_exec_stats.entry_success++;
   else
      g_exec_stats.entry_fail++;

   LogEvent(ok ? "ENTRY" : "ENTRY_FAIL",
            is_buy ? "LongEntry" : "ShortEntry",
            is_buy ? "BUY" : "SELL",
            volume,
            entry,
            sl,
            tp,
            StringFormat("ret=%d;desc=%s", ret, g_trade.ResultRetcodeDescription()));

   if(ok)
   {
      SaveLastTradeBar(signal_bar);
      ClearPartialDoneTicket();
   }

   return ok;
}

void ManageOpenPosition(const datetime now, const bool is_new_signal_bar)
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

   if(InpUseMaxBarsInTrade && InpMaxBarsInTrade > 0)
   {
      int tf_seconds = PeriodSeconds(PERIOD_H1);
      if(tf_seconds > 0)
      {
         int bars_live = (int)((now - open_time) / tf_seconds);
         if(bars_live >= InpMaxBarsInTrade)
         {
            CloseStrategyPosition(ticket, "TimeStop");
            return;
         }
      }
   }

   double atr_h1 = 0.0;
   if(!ReadBufferValue(g_h1_atr_handle, 0, 1, atr_h1) || atr_h1 <= 0.0)
      return;

   double bid = 0.0;
   double ask = 0.0;
   if(!GetCurrentBidAsk(bid, ask))
      return;

   bool is_buy = (type == POSITION_TYPE_BUY);
   double current_price = is_buy ? bid : ask;
   double move = is_buy ? (current_price - open_price) : (open_price - current_price);
   double fallback = (sl > 0.0) ? MathAbs(open_price - sl) : ((double)InpMinSL_Points * _Point);
   double risk = ParseRiskDistance(comment, fallback);
   if(risk <= 0.0)
      return;

   double r_multiple = move / risk;
   double new_sl = sl;
   bool should_modify = false;

   if(InpUsePartialClose && InpPartialPct > 0.0 && r_multiple >= InpPartialAtR && !IsPartialDoneForTicket(ticket))
   {
      double min_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      if(step <= 0.0)
         step = min_volume;

      double close_volume = NormalizeVolume(volume * (InpPartialPct / 100.0));
      if(close_volume >= min_volume && close_volume < volume - (PARTIAL_MIN_REMAIN_STEP * step))
      {
         g_exec_stats.partial_attempts++;
         bool partial_ok = g_trade.PositionClosePartial(ticket, close_volume);
         int retp = (int)g_trade.ResultRetcode();
         bool partial_done = partial_ok && (retp == TRADE_RETCODE_DONE || retp == TRADE_RETCODE_DONE_PARTIAL);
         if(partial_done)
         {
            g_exec_stats.partial_success++;
            MarkPartialDoneTicket(ticket);
         }
         LogEvent(partial_done ? "PARTIAL_CLOSE" : "PARTIAL_CLOSE_FAIL",
                  "RiskManagement",
                  is_buy ? "BUY" : "SELL",
                  close_volume,
                  current_price,
                  sl,
                  tp,
                  StringFormat("ret=%d;R=%.2f", retp, r_multiple));
      }
   }

   if(r_multiple >= InpBreakEvenAtR)
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

   if(InpUseTrailingAfterBE && InpATR_Trail_Mult > 0.0 && r_multiple >= InpBreakEvenAtR)
   {
      double trail_dist = InpATR_Trail_Mult * atr_h1;
      if(trail_dist > 0.0)
      {
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
   }

   if(!should_modify || new_sl <= 0.0)
      return;

   if(sl > 0.0 && MathAbs(new_sl - sl) < (2.0 * _Point))
      return;
   if(InpUseTrailingAfterBE && !is_new_signal_bar)
      return;

   g_exec_stats.modify_attempts++;
   bool modified = g_trade.PositionModify(ticket, new_sl, tp);
   int ret = (int)g_trade.ResultRetcode();
   bool ok = modified && (ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_DONE_PARTIAL);
   if(ok)
      g_exec_stats.modify_success++;

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
   if(!is_new_signal_bar)
      return;
   if(signal_bar <= 0)
      return;

   if(!CanTradeThisBar(signal_bar))
      return;

   if(IsCooldownBlocked(signal_bar))
   {
      LogEvent("ENTRY_SKIP", "CooldownAfterLoss", "-", 0.0, 0.0, 0.0, 0.0, "loss cooldown active");
      return;
   }

   if(!IsWithinTradingHours(now))
      return;

   if(IsKillSwitchActive(now))
   {
      LogEvent("ENTRY_SKIP", "KillSwitch", "-", 0.0, 0.0, 0.0, 0.0, "daily-loss or consecutive-loss");
      return;
   }

   string market_reason = "";
   if(!IsMarketTradable(now, market_reason))
   {
      LogEvent("ENTRY_SKIP", market_reason, "-", 0.0, 0.0, 0.0, 0.0, "market guard");
      return;
   }

   if(InpUseNewsFilter && IsNewsBlocked(now))
   {
      LogEvent("ENTRY_SKIP", "NewsBlock", "-", 0.0, 0.0, 0.0, 0.0, "high-impact event window");
      return;
   }

   double atr_h1 = 0.0;
   if(!ReadBufferValue(g_h1_atr_handle, 0, 1, atr_h1) || atr_h1 <= 0.0)
      return;

   int trend = GetTrendDirection();
   if(trend == 0)
      return;

   if(!CheckEntrySignal(trend, atr_h1))
      return;

   ulong ticket = 0;
   long type = -1;
   double open_price = 0.0;
   double sl = 0.0;
   double tp = 0.0;
   double volume = 0.0;
   datetime open_time = 0;
   string comment = "";

   bool has_strategy_position = GetStrategyPosition(ticket, type, open_price, sl, tp, volume, open_time, comment);
   if(has_strategy_position)
   {
      bool is_buy = (type == POSITION_TYPE_BUY);
      if((trend > 0 && is_buy) || (trend < 0 && !is_buy))
         return;

      if(!CloseStrategyPosition(ticket, "TrendReversal"))
         return;
   }

   if(InpOnePositionOnly && HasAnyOpenPosition())
   {
      LogEvent("ENTRY_SKIP", "OnePositionPolicy", "-", 0.0, 0.0, 0.0, 0.0, "another position open");
      return;
   }

   OpenTrade(trend > 0, atr_h1, signal_bar);
}

int OnInit()
{
   string symbol_upper = ToUpperCopy(_Symbol);
   if(StringFind(symbol_upper, "XAUUSD") < 0)
      Print("Warning: This EA is designed for XAUUSD. Current symbol may not match planned behavior.");

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(30);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   ParseNewsCurrencies();
   InitPersistentState();
   ResetExecStats();
   InitTradeLog();

   datetime now = TimeTradeServer();
   if(now <= 0)
      now = TimeCurrent();
   EnsureDailyState(now);

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
            StringFormat("H4 fast=%d slow=%d pullback=%s breakout=%s one_pos=%s",
                         InpFastEMA_H4,
                         InpSlowEMA_H4,
                         InpUsePullbackEntry ? "true" : "false",
                         InpUseBreakoutContinuation ? "true" : "false",
                         InpOnePositionOnly ? "true" : "false"));

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EmitExecSummary();
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

   EnsureDailyState(now);

   datetime signal_bar = 0;
   bool is_new_signal_bar = IsNewSignalBar(signal_bar);

   ManageOpenPosition(now, is_new_signal_bar);
   TryOpenEntry(now, signal_bar, is_new_signal_bar);
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
   if((int)magic != InpMagic)
      return;

   long deal_type = HistoryDealGetInteger(deal_ticket, DEAL_TYPE);
   long deal_entry = HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
   double volume = HistoryDealGetDouble(deal_ticket, DEAL_VOLUME);
   double price = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
   double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);
   double swap = HistoryDealGetDouble(deal_ticket, DEAL_SWAP);
   double commission = HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);
   datetime deal_time = (datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME);

   string side = "OTHER";
   if(deal_type == DEAL_TYPE_BUY)
      side = "BUY";
   else if(deal_type == DEAL_TYPE_SELL)
      side = "SELL";

   string evt = (deal_entry == DEAL_ENTRY_IN) ? "DEAL_IN" : "DEAL_OUT";

   if(deal_entry == DEAL_ENTRY_OUT)
   {
      EnsureDailyState(deal_time);
      double pnl = profit + swap + commission;
      g_daily_realized_pnl += pnl;
      if(pnl < 0.0)
      {
         g_consecutive_losses++;
         SaveLastLossCloseTime(deal_time);
      }
      else if(pnl > 0.0)
      {
         g_consecutive_losses = 0;
      }

      ulong t = 0;
      long ty = -1;
      double op = 0.0;
      double sl = 0.0;
      double tp = 0.0;
      double vol = 0.0;
      datetime ot = 0;
      string cm = "";
      if(!GetStrategyPosition(t, ty, op, sl, tp, vol, ot, cm))
         ClearPartialDoneTicket();
   }

   LogEvent(evt,
            StringFormat("profit=%.2f", profit),
            side,
            volume,
            price,
            0.0,
            0.0,
            StringFormat("deal=%I64d;ret=%d", deal_ticket, (int)result.retcode));
}

double OnTester()
{
   double pf = TesterStatistics(STAT_PROFIT_FACTOR);
   double dd = TesterStatistics(STAT_BALANCE_DDREL_PERCENT);
   double trades = TesterStatistics(STAT_TRADES);
   double net = TesterStatistics(STAT_PROFIT);
   double initial = TesterStatistics(STAT_INITIAL_DEPOSIT);
   if(initial <= 0.0)
      initial = 10000.0;

   double balance_ratio = (initial + net) / initial;
   if(pf <= 0.0 || trades <= 0.0)
      return -10000.0 + balance_ratio;

   double score = (balance_ratio * 100.0) + (pf * 10.0);

   if(balance_ratio < 1.8)
      score -= (1.8 - balance_ratio) * 200.0;
   if(pf < 1.75)
      score -= (1.75 - pf) * 50.0;
   if(dd > 20.0)
      score -= (dd - 20.0) * 10.0;
   if(InpMinTradesForScore > 0 && trades < InpMinTradesForScore)
      score -= (InpMinTradesForScore - trades) * 2.0;

   return score;
}
