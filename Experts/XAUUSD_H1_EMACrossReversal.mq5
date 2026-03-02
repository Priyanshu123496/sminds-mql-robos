#property copyright "SMINDS"
#property version   "1.00"
#property strict
#property description "XAUUSD H1 EMA cross reversal EA with production robustness controls"

#include <Trade/Trade.mqh>

#define EA_MAGIC_H1 26022311
#define NEWS_POLL_SECONDS 60

input ENUM_TIMEFRAMES SignalTF = PERIOD_H1;
input double RiskPerTradePct = 0.5;
input int EmaFast = 20;
input int EmaSlow = 50;
input bool UseBarCloseConfirmation = true;
input int FixedSLPoints = 50;
input bool UseFixedTP = false;
input int FixedTPPoints = 100;
input bool UseAtrTrail = true;
input int AtrPeriod = 14;
input double TrailAtrMult = 1.5;
input bool UseBreakEven = true;
input double BreakEvenR = 1.0;
input bool UseAdxFilter = false;
input int AdxPeriod = 14;
input double AdxMin = 18.0;
input bool UseVolatilityFilter = false;
input double MaxAtrToPricePct = 0.60;
input bool UseSessionFilter = true;
input int SessionStartServerHour = 0;
input int SessionEndServerHour = 24;
input bool UseNewsFilter = true;
input int NewsBlockBeforeMin = 30;
input int NewsBlockAfterMin = 30;
input string NewsCurrencies = "USD";
input int MaxSpreadPoints = 350;
input int FridayFlatHour = 21;
input int FridayFlatMinute = 45;
input double CommissionPerLotRT = 7.0;
input int MinTradesForScore = 150;

input bool InterpretFixedSLAsPips = true;
input int PipSizePoints = 10;
input double MaxMarginUsePct = 40.0;
input double MaxVolumeLots = 2.0;
input bool RetryOnNoMoney = true;
input int MaxEntryRetries = 2;
input bool ManageStopsOnNewBarOnly = true;
input int MinStopUpdatePoints = 5;
input int MinSecondsBetweenStopUpdates = 30;
input double MaxEntryFailRatePct = 2.0;
input bool UseTrendRegimeFilter = true;
input int RegimeEmaPeriod = 200;
input bool RequireRegimeSlope = true;
input int RegimeSlopeBars = 3;
input double MinRegimeSlopeAtr = 0.05;
input bool UseAtrStop = true;
input double AtrStopMult = 2.2;
input bool UseAtrTarget = true;
input double AtrTargetMult = 3.2;
input bool UseCooldownAfterLoss = true;
input int CooldownBarsAfterLoss = 3;
input bool UsePartialExit = true;
input double PartialExitR = 1.2;
input double PartialExitPct = 50.0;

CTrade g_trade;

int g_ema_fast_handle = INVALID_HANDLE;
int g_ema_slow_handle = INVALID_HANDLE;
int g_regime_ema_handle = INVALID_HANDLE;
int g_atr_handle = INVALID_HANDLE;
int g_adx_handle = INVALID_HANDLE;

datetime g_last_signal_bar = 0;
string g_last_trade_bar_key = "";
double g_last_trade_bar = 0.0;
datetime g_last_stop_update_time = 0;
string g_last_loss_time_key = "";
double g_last_loss_close_time = 0.0;
string g_partial_done_ticket_key = "";
double g_partial_done_ticket = 0.0;

string g_news_currencies[];
datetime g_last_news_eval = 0;
bool g_news_blocked_cache = false;
ulong g_calendar_change_id = 0;
datetime g_last_calendar_poll = 0;
bool g_calendar_enabled = false;

int g_log_handle = INVALID_HANDLE;
string g_log_file = "";

struct ExecStats
{
   ulong entry_attempts;
   ulong entry_success;
   ulong entry_fail_no_money;
   ulong entry_fail_other;
   ulong stop_modify_attempts;
   ulong stop_modify_success;
   ulong partial_close_attempts;
   ulong partial_close_success;
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
   g_exec_stats.entry_fail_no_money = 0;
   g_exec_stats.entry_fail_other = 0;
   g_exec_stats.stop_modify_attempts = 0;
   g_exec_stats.stop_modify_success = 0;
    g_exec_stats.partial_close_attempts = 0;
    g_exec_stats.partial_close_success = 0;
}

string BuildExecSummary()
{
   double fail_rate = 0.0;
   double no_money_rate = 0.0;

   if(g_exec_stats.entry_attempts > 0)
   {
      double fails = (double)(g_exec_stats.entry_fail_no_money + g_exec_stats.entry_fail_other);
      fail_rate = (100.0 * fails) / (double)g_exec_stats.entry_attempts;
      no_money_rate = (100.0 * (double)g_exec_stats.entry_fail_no_money) / (double)g_exec_stats.entry_attempts;
   }

   return StringFormat(
      "entry_attempts=%I64u;entry_success=%I64u;entry_fail_no_money=%I64u;entry_fail_other=%I64u;stop_modify_attempts=%I64u;stop_modify_success=%I64u;partial_close_attempts=%I64u;partial_close_success=%I64u;entry_fail_rate_pct=%.4f;no_money_fail_rate_pct=%.4f;entry_fail_threshold_pct=%.4f",
      g_exec_stats.entry_attempts,
      g_exec_stats.entry_success,
      g_exec_stats.entry_fail_no_money,
      g_exec_stats.entry_fail_other,
      g_exec_stats.stop_modify_attempts,
      g_exec_stats.stop_modify_success,
      g_exec_stats.partial_close_attempts,
      g_exec_stats.partial_close_success,
      fail_rate,
      no_money_rate,
      MaxEntryFailRatePct
   );
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

   if(volume_step <= 0.0 || min_volume <= 0.0 || max_volume <= 0.0)
      return 0.0;

   double clipped = MathMax(min_volume, MathMin(max_volume, raw_volume));
   double stepped = MathFloor(clipped / volume_step) * volume_step;
   int digits = VolumeDigits(volume_step);
   return NormalizeDouble(stepped, digits);
}

int GetEffectiveSLPoints()
{
   int raw_points = FixedSLPoints;
   if(InterpretFixedSLAsPips)
      raw_points *= MathMax(1, PipSizePoints);

   if(raw_points < 1)
      raw_points = 1;

   return raw_points;
}

double GetStopDistancePrice()
{
   int points = GetEffectiveSLPoints();
   return (double)points * _Point;
}

double GetDynamicStopDistancePrice(const double atr)
{
   double fixed_distance = GetStopDistancePrice();
   if(!UseAtrStop || atr <= 0.0 || AtrStopMult <= 0.0)
      return fixed_distance;

   double atr_distance = AtrStopMult * atr;
   if(atr_distance < _Point)
      atr_distance = _Point;

   return atr_distance;
}

double GetDynamicTargetDistancePrice(const double atr)
{
   if(UseAtrTarget && atr > 0.0 && AtrTargetMult > 0.0)
   {
      double atr_distance = AtrTargetMult * atr;
      if(atr_distance < _Point)
         atr_distance = _Point;
      return atr_distance;
   }

   if(!UseFixedTP || FixedTPPoints <= 0)
      return 0.0;

   double fixed_tp = (double)FixedTPPoints * _Point;
   if(fixed_tp < _Point)
      fixed_tp = _Point;
   return fixed_tp;
}

double CalculateRiskVolume(const double stop_distance)
{
   if(stop_distance <= 0.0)
      return 0.0;

   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tick_size <= 0.0 || tick_value <= 0.0)
      return 0.0;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_amount = equity * (RiskPerTradePct / 100.0);
   if(risk_amount <= 0.0)
      return 0.0;

   double ticks_to_sl = stop_distance / tick_size;
   double loss_per_lot = (ticks_to_sl * tick_value) + CommissionPerLotRT;
   if(loss_per_lot <= 0.0)
      return 0.0;

   double raw_volume = risk_amount / loss_per_lot;
   if(MaxVolumeLots > 0.0)
      raw_volume = MathMin(raw_volume, MaxVolumeLots);

   return NormalizeVolume(raw_volume);
}

double CapVolumeByMargin(const ENUM_ORDER_TYPE order_type,
                         const double order_price,
                         const double requested_volume,
                         bool &was_capped,
                         bool &below_min_lot)
{
   was_capped = false;
   below_min_lot = false;

   double min_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volume_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(min_volume <= 0.0 || volume_step <= 0.0)
      return 0.0;

   double candidate = NormalizeVolume(requested_volume);
   if(candidate <= 0.0)
      return 0.0;

   double allowed_by_pct = AccountInfoDouble(ACCOUNT_EQUITY) * (MaxMarginUsePct / 100.0);
   double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double allowed_margin = MathMin(allowed_by_pct, free_margin);

   if(MaxMarginUsePct <= 0.0 || allowed_margin <= 0.0)
      return candidate;

   double margin_required = 0.0;
   if(OrderCalcMargin(order_type, _Symbol, candidate, order_price, margin_required) && margin_required <= allowed_margin + 1e-8)
      return candidate;

   double best = 0.0;
   for(double vol = candidate; vol >= min_volume - 1e-8; vol -= volume_step)
   {
      double check_vol = NormalizeVolume(vol);
      if(check_vol < min_volume - 1e-8)
         break;

      margin_required = 0.0;
      if(!OrderCalcMargin(order_type, _Symbol, check_vol, order_price, margin_required))
         continue;
      if(margin_required <= allowed_margin + 1e-8)
      {
         best = check_vol;
         break;
      }
   }

   if(best <= 0.0)
   {
      below_min_lot = true;
      return 0.0;
   }

   if(best < candidate - 1e-8)
      was_capped = true;

   return best;
}

double ReduceVolumeForRetry(const double current_volume)
{
   double min_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(min_volume <= 0.0 || step <= 0.0)
      return 0.0;

   double reduced = NormalizeVolume(current_volume * 0.70);
   if(reduced >= current_volume - 1e-8)
      reduced = NormalizeVolume(current_volume - step);

   if(reduced < min_volume - 1e-8)
      return 0.0;

   return reduced;
}

double ComputePartialCloseVolume(const double current_volume)
{
   if(!UsePartialExit || PartialExitPct <= 0.0 || PartialExitPct >= 100.0)
      return 0.0;

   double min_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(min_volume <= 0.0)
      return 0.0;

   double close_volume = NormalizeVolume(current_volume * (PartialExitPct / 100.0));
   if(close_volume < min_volume - 1e-8)
      return 0.0;

   double remaining = NormalizeVolume(current_volume - close_volume);
   if(remaining < min_volume - 1e-8)
   {
      close_volume = NormalizeVolume(current_volume - min_volume);
      remaining = NormalizeVolume(current_volume - close_volume);
   }

   if(close_volume < min_volume - 1e-8 || remaining < min_volume - 1e-8)
      return 0.0;

   return close_volume;
}

bool IsWithinSession(const datetime now)
{
   if(!UseSessionFilter)
      return true;

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

void InitLastTradeBarState()
{
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   g_last_trade_bar_key = StringFormat("H1_EMA_LAST_BAR_%I64d_%s", login, _Symbol);

   if(GlobalVariableCheck(g_last_trade_bar_key))
      g_last_trade_bar = GlobalVariableGet(g_last_trade_bar_key);
   else
      g_last_trade_bar = 0.0;
}

void InitPersistentState()
{
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   g_last_loss_time_key = StringFormat("H1_EMA_LAST_LOSS_%I64d_%s", login, _Symbol);
   g_partial_done_ticket_key = StringFormat("H1_EMA_PARTIAL_DONE_%I64d_%s", login, _Symbol);

   if(GlobalVariableCheck(g_last_loss_time_key))
      g_last_loss_close_time = GlobalVariableGet(g_last_loss_time_key);
   else
      g_last_loss_close_time = 0.0;

   if(GlobalVariableCheck(g_partial_done_ticket_key))
      g_partial_done_ticket = GlobalVariableGet(g_partial_done_ticket_key);
   else
      g_partial_done_ticket = 0.0;
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

void SaveLastLossCloseTime(const datetime close_time)
{
   g_last_loss_close_time = (double)close_time;
   if(StringLen(g_last_loss_time_key) > 0)
      GlobalVariableSet(g_last_loss_time_key, g_last_loss_close_time);
}

bool IsCooldownBlocked(const datetime signal_bar)
{
   if(!UseCooldownAfterLoss || CooldownBarsAfterLoss <= 0)
      return false;

   if(g_last_loss_close_time <= 0.0)
      return false;

   int tf_seconds = PeriodSeconds(SignalTF);
   if(tf_seconds <= 0)
      return false;

   int bars_since_loss = (int)((signal_bar - (datetime)g_last_loss_close_time) / tf_seconds);
   return (bars_since_loss < CooldownBarsAfterLoss);
}

bool IsPartialDoneForTicket(const ulong ticket)
{
   if(ticket == 0 || g_partial_done_ticket <= 0.0)
      return false;
   return ((ulong)g_partial_done_ticket == ticket);
}

void MarkPartialDone(const ulong ticket)
{
   g_partial_done_ticket = (double)ticket;
   if(StringLen(g_partial_done_ticket_key) > 0)
      GlobalVariableSet(g_partial_done_ticket_key, g_partial_done_ticket);
}

bool InitTradeLog()
{
   string stamp = TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS);
   StringReplace(stamp, ":", "-");
   StringReplace(stamp, ".", "-");
   StringReplace(stamp, " ", "_");

   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   g_log_file = StringFormat("XAUUSD_H1_EMACrossReversal_%I64d_%s.csv", login, stamp);
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
             "retcode",
             "retcode_desc",
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
              const int retcode,
              const string retcode_desc,
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
             IntegerToString(retcode),
             retcode_desc,
             DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2),
             DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2),
             comment);
   FileFlush(g_log_handle);
}

void EmitExecSummary()
{
   string summary = BuildExecSummary();
   Print(summary);
   LogEvent("EXEC_SUMMARY", "EndOfRun", "-", 0.0, 0.0, 0.0, 0.0, 0, "none", summary);
}

bool InitIndicators()
{
   g_ema_fast_handle = iMA(_Symbol, SignalTF, EmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_ema_slow_handle = iMA(_Symbol, SignalTF, EmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_regime_ema_handle = iMA(_Symbol, SignalTF, RegimeEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_atr_handle = iATR(_Symbol, SignalTF, AtrPeriod);
   g_adx_handle = iADX(_Symbol, SignalTF, AdxPeriod);

   if(g_ema_fast_handle == INVALID_HANDLE ||
      g_ema_slow_handle == INVALID_HANDLE ||
      g_regime_ema_handle == INVALID_HANDLE ||
      g_atr_handle == INVALID_HANDLE ||
      g_adx_handle == INVALID_HANDLE)
   {
      Print("Failed to initialize one or more indicator handles.");
      return false;
   }

   return true;
}

void ReleaseIndicators()
{
   if(g_ema_fast_handle != INVALID_HANDLE)
      IndicatorRelease(g_ema_fast_handle);
   if(g_ema_slow_handle != INVALID_HANDLE)
      IndicatorRelease(g_ema_slow_handle);
   if(g_regime_ema_handle != INVALID_HANDLE)
      IndicatorRelease(g_regime_ema_handle);
   if(g_atr_handle != INVALID_HANDLE)
      IndicatorRelease(g_atr_handle);
   if(g_adx_handle != INVALID_HANDLE)
      IndicatorRelease(g_adx_handle);
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
      if((long)PositionGetInteger(POSITION_MAGIC) != EA_MAGIC_H1)
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
      if(t == 0)
         continue;
      if(!PositionSelectByTicket(t))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != EA_MAGIC_H1)
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

   double bid = 0.0;
   double ask = 0.0;
   GetCurrentBidAsk(bid, ask);
   double price = (type == POSITION_TYPE_BUY) ? bid : ask;
   string side = (type == POSITION_TYPE_BUY) ? "BUY" : "SELL";

   bool sent = g_trade.PositionClose(ticket);
   int ret = (int)g_trade.ResultRetcode();
   string desc = g_trade.ResultRetcodeDescription();
   bool ok = sent && (ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_DONE_PARTIAL);

   LogEvent(ok ? "POSITION_CLOSE" : "POSITION_CLOSE_FAIL",
            reason,
            side,
            volume,
            price,
            sl,
            tp,
            ret,
            desc,
            StringFormat("ticket=%I64u", ticket));
   return ok;
}

bool OpenTradeWithRetries(const bool is_buy,
                          const double atr,
                          const datetime signal_bar)
{
   double bid = 0.0;
   double ask = 0.0;
   if(!GetCurrentBidAsk(bid, ask))
      return false;

   double entry = is_buy ? ask : bid;
   double sl_distance = GetDynamicStopDistancePrice(atr);
   if(sl_distance <= 0.0)
      return false;

   double tp_distance = GetDynamicTargetDistancePrice(atr);

   double raw_volume = CalculateRiskVolume(sl_distance);
   if(raw_volume <= 0.0)
   {
      LogEvent("ENTRY_SKIP",
               "VolumeZero",
               is_buy ? "BUY" : "SELL",
               0.0,
               entry,
               0.0,
               0.0,
               0,
               "none",
               "risk sizing");
      return false;
   }

   ENUM_ORDER_TYPE ord_type = is_buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   bool margin_capped = false;
   bool margin_below_min = false;
   double volume = CapVolumeByMargin(ord_type, entry, raw_volume, margin_capped, margin_below_min);

   if(margin_below_min || volume <= 0.0)
   {
      LogEvent("ENTRY_SKIP",
               "MarginCapBelowMinLot",
               is_buy ? "BUY" : "SELL",
               0.0,
               entry,
               0.0,
               0.0,
               0,
               "none",
               StringFormat("raw=%.2f", raw_volume));
      return false;
   }

   if(margin_capped || volume < raw_volume - 1e-8)
   {
      LogEvent("ENTRY_INFO",
               "VolumeCapped",
               is_buy ? "BUY" : "SELL",
               volume,
               entry,
               0.0,
               0.0,
               0,
               "none",
               StringFormat("raw=%.2f", raw_volume));
   }

   double sl = is_buy ? (entry - sl_distance) : (entry + sl_distance);
   double tp = 0.0;
   if(tp_distance > 0.0)
      tp = is_buy ? (entry + tp_distance) : (entry - tp_distance);

   sl = NormalizePrice(sl);
   tp = NormalizePrice(tp);

   string comment = "EMAR|R=" + DoubleToString(sl_distance, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));

   int attempts_allowed = MathMax(0, MaxEntryRetries);
   for(int attempt = 0; attempt <= attempts_allowed; attempt++)
   {
      g_exec_stats.entry_attempts++;

      bool sent = false;
      if(is_buy)
         sent = g_trade.Buy(volume, _Symbol, 0.0, sl, tp, comment);
      else
         sent = g_trade.Sell(volume, _Symbol, 0.0, sl, tp, comment);

      int ret = (int)g_trade.ResultRetcode();
      string desc = g_trade.ResultRetcodeDescription();
      bool ok = sent && (ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_DONE_PARTIAL || ret == TRADE_RETCODE_PLACED);
      bool is_no_money = (ret == TRADE_RETCODE_NO_MONEY || ret == 10019);

      if(ok)
      {
         g_exec_stats.entry_success++;
         SaveLastTradeBar(signal_bar);
         LogEvent("ENTRY",
                  is_buy ? "CrossUp" : "CrossDown",
                  is_buy ? "BUY" : "SELL",
                  volume,
                  entry,
                  sl,
                  tp,
                  ret,
                  desc,
                  StringFormat("attempt=%d", attempt + 1));
         return true;
      }

      if(is_no_money)
         g_exec_stats.entry_fail_no_money++;
      else
         g_exec_stats.entry_fail_other++;

      LogEvent("ENTRY_FAIL",
               is_no_money ? "NoMoney" : "EntryFail",
               is_buy ? "BUY" : "SELL",
               volume,
               entry,
               sl,
               tp,
               ret,
               desc,
               StringFormat("attempt=%d", attempt + 1));

      if(!is_no_money || !RetryOnNoMoney || attempt >= attempts_allowed)
         return false;

      double reduced = ReduceVolumeForRetry(volume);
      if(reduced <= 0.0 || reduced >= volume - 1e-8)
      {
         LogEvent("ENTRY_SKIP",
                  "MarginCapBelowMinLot",
                  is_buy ? "BUY" : "SELL",
                  reduced,
                  entry,
                  sl,
                  tp,
                  ret,
                  desc,
                  "retry reduction reached min lot");
         return false;
      }

      LogEvent("ENTRY_RETRY",
               "RetryReducedVolume",
               is_buy ? "BUY" : "SELL",
               reduced,
               entry,
               sl,
               tp,
               ret,
               desc,
               StringFormat("from=%.2f", volume));
      volume = reduced;
   }

   return false;
}

bool DetectCrossSignal(const bool is_new_signal_bar, int &direction)
{
   direction = 0;

   if(UseBarCloseConfirmation && !is_new_signal_bar)
      return false;

   int current_shift = UseBarCloseConfirmation ? 1 : 0;
   int previous_shift = UseBarCloseConfirmation ? 2 : 1;

   double fast_curr = 0.0;
   double fast_prev = 0.0;
   double slow_curr = 0.0;
   double slow_prev = 0.0;

   if(!ReadBufferValue(g_ema_fast_handle, 0, current_shift, fast_curr))
      return false;
   if(!ReadBufferValue(g_ema_fast_handle, 0, previous_shift, fast_prev))
      return false;
   if(!ReadBufferValue(g_ema_slow_handle, 0, current_shift, slow_curr))
      return false;
   if(!ReadBufferValue(g_ema_slow_handle, 0, previous_shift, slow_prev))
      return false;

   if(fast_prev <= slow_prev && fast_curr > slow_curr)
   {
      direction = 1;
      return true;
   }

   if(fast_prev >= slow_prev && fast_curr < slow_curr)
   {
      direction = -1;
      return true;
   }

   return false;
}

bool TrendRegimeFilterPass(const bool is_buy, string &reason_text)
{
   reason_text = "";
   if(!UseTrendRegimeFilter)
      return true;

   int shift = UseBarCloseConfirmation ? 1 : 0;
   int slope_bars = MathMax(1, RegimeSlopeBars);
   int slope_shift = shift + slope_bars;

   double regime_curr = 0.0;
   double regime_old = 0.0;
   if(!ReadBufferValue(g_regime_ema_handle, 0, shift, regime_curr))
   {
      reason_text = "RegimeEmaReadFail";
      return false;
   }
   if(!ReadBufferValue(g_regime_ema_handle, 0, slope_shift, regime_old))
   {
      reason_text = "RegimeSlopeReadFail";
      return false;
   }

   double closes[];
   int copied = CopyClose(_Symbol, SignalTF, shift, 1, closes);
   if(copied != 1 || !MathIsValidNumber(closes[0]) || closes[0] <= 0.0)
   {
      reason_text = "RegimeCloseReadFail";
      return false;
   }

   double atr = 0.0;
   if(!ReadBufferValue(g_atr_handle, 0, shift, atr) || atr <= 0.0)
   {
      reason_text = "RegimeAtrReadFail";
      return false;
   }

   double close_price = closes[0];
   if(is_buy && close_price <= regime_curr)
   {
      reason_text = "PriceBelowRegime";
      return false;
   }
   if(!is_buy && close_price >= regime_curr)
   {
      reason_text = "PriceAboveRegime";
      return false;
   }

   if(!RequireRegimeSlope)
      return true;

   double slope_atr = (regime_curr - regime_old) / (atr * slope_bars);
   if(is_buy && slope_atr < MinRegimeSlopeAtr)
   {
      reason_text = StringFormat("RegimeSlopeLow(%.4f<%.4f)", slope_atr, MinRegimeSlopeAtr);
      return false;
   }
   if(!is_buy && slope_atr > -MinRegimeSlopeAtr)
   {
      reason_text = StringFormat("RegimeSlopeHigh(%.4f>%.4f)", slope_atr, -MinRegimeSlopeAtr);
      return false;
   }

   return true;
}

bool EntryFiltersPass(const datetime now, const bool is_buy)
{
   if(!IsWithinSession(now))
      return false;

   if(IsFridayFlatTime(now))
      return false;

   int spread = GetSpreadPoints();
   if(spread > MaxSpreadPoints)
   {
      LogEvent("ENTRY_SKIP",
               "SpreadGuard",
               is_buy ? "BUY" : "SELL",
               0.0,
               0.0,
               0.0,
               0.0,
               0,
               "none",
               StringFormat("spread=%d", spread));
      return false;
   }

   if(IsNewsBlocked(now))
   {
      LogEvent("ENTRY_SKIP",
               "NewsBlock",
               is_buy ? "BUY" : "SELL",
               0.0,
               0.0,
               0.0,
               0.0,
               0,
               "none",
               "high-impact event window");
      return false;
   }

   if(UseAdxFilter)
   {
      double adx = 0.0;
      int adx_shift = UseBarCloseConfirmation ? 1 : 0;
      if(!ReadBufferValue(g_adx_handle, 0, adx_shift, adx) || adx < AdxMin)
      {
         LogEvent("ENTRY_SKIP",
                  "AdxLow",
                  is_buy ? "BUY" : "SELL",
                  0.0,
                  0.0,
                  0.0,
                  0.0,
                  0,
                  "none",
                  StringFormat("adx=%.2f;min=%.2f", adx, AdxMin));
         return false;
      }
   }

   if(UseVolatilityFilter)
   {
      double atr = 0.0;
      int atr_shift = UseBarCloseConfirmation ? 1 : 0;
      if(!ReadBufferValue(g_atr_handle, 0, atr_shift, atr) || atr <= 0.0)
         return false;

      double closes[];
      int copied = CopyClose(_Symbol, SignalTF, atr_shift, 1, closes);
      if(copied != 1 || !MathIsValidNumber(closes[0]) || closes[0] <= 0.0)
         return false;

      double atr_to_price_pct = (atr / closes[0]) * 100.0;
      if(atr_to_price_pct > MaxAtrToPricePct)
      {
         LogEvent("ENTRY_SKIP",
                  "VolatilityFilter",
                  is_buy ? "BUY" : "SELL",
                  0.0,
                  closes[0],
                  0.0,
                  0.0,
                  0,
                  "none",
                  StringFormat("atr_pct=%.4f;max=%.4f", atr_to_price_pct, MaxAtrToPricePct));
         return false;
      }
   }

   string regime_reason = "";
   if(!TrendRegimeFilterPass(is_buy, regime_reason))
   {
      LogEvent("ENTRY_SKIP",
               "TrendRegimeFilter",
               is_buy ? "BUY" : "SELL",
               0.0,
               0.0,
               0.0,
               0.0,
               0,
               "none",
               regime_reason);
      return false;
   }

   return true;
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

   bool is_buy = (type == POSITION_TYPE_BUY);
   double bid = 0.0;
   double ask = 0.0;
   if(!GetCurrentBidAsk(bid, ask))
      return;
   double current_price = is_buy ? bid : ask;

   double atr = 0.0;
   int atr_shift = UseBarCloseConfirmation ? 1 : 0;
   if(!ReadBufferValue(g_atr_handle, 0, atr_shift, atr) || atr <= 0.0)
      return;

   double fallback_risk = (sl > 0.0) ? MathAbs(open_price - sl) : GetDynamicStopDistancePrice(atr);
   double initial_risk = ParseRiskDistance(comment, fallback_risk);
   if(initial_risk <= 0.0)
      return;

   double move = is_buy ? (current_price - open_price) : (open_price - current_price);
   double r_multiple = move / initial_risk;

   if(UsePartialExit && r_multiple >= PartialExitR && !IsPartialDoneForTicket(ticket))
   {
      double partial_volume = ComputePartialCloseVolume(volume);
      if(partial_volume > 0.0)
      {
         g_exec_stats.partial_close_attempts++;
         bool partial_closed = g_trade.PositionClosePartial(ticket, partial_volume);
         int partial_ret = (int)g_trade.ResultRetcode();
         string partial_desc = g_trade.ResultRetcodeDescription();
         bool partial_ok = partial_closed && (partial_ret == TRADE_RETCODE_DONE || partial_ret == TRADE_RETCODE_DONE_PARTIAL);

         if(partial_ok)
         {
            g_exec_stats.partial_close_success++;
            MarkPartialDone(ticket);
            volume = MathMax(0.0, volume - partial_volume);
         }

         LogEvent(partial_ok ? "PARTIAL_CLOSE" : "PARTIAL_CLOSE_FAIL",
                  "RiskManagement",
                  is_buy ? "BUY" : "SELL",
                  partial_volume,
                  current_price,
                  sl,
                  tp,
                  partial_ret,
                  partial_desc,
                  StringFormat("R=%.2f", r_multiple));
      }
   }

   double new_sl = sl;
   bool should_modify = false;

   if(UseBreakEven && r_multiple >= BreakEvenR)
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

   if(UseAtrTrail)
   {
      double trail_distance = TrailAtrMult * atr;
      if(trail_distance > 0.0)
      {
         double trail_sl = is_buy ? (current_price - trail_distance) : (current_price + trail_distance);
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

   if(ManageStopsOnNewBarOnly && !is_new_signal_bar)
      return;

   if(MinSecondsBetweenStopUpdates > 0 &&
      g_last_stop_update_time > 0 &&
      (now - g_last_stop_update_time) < MinSecondsBetweenStopUpdates)
      return;

   double min_step = (double)MathMax(0, MinStopUpdatePoints) * _Point;
   if(min_step > 0.0 && sl > 0.0 && MathAbs(new_sl - sl) < min_step)
      return;

   g_exec_stats.stop_modify_attempts++;

   bool modified = g_trade.PositionModify(ticket, new_sl, tp);
   int ret = (int)g_trade.ResultRetcode();
   string desc = g_trade.ResultRetcodeDescription();
   bool ok = modified && (ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_DONE_PARTIAL);

   if(ok)
   {
      g_exec_stats.stop_modify_success++;
      g_last_stop_update_time = now;
   }

   LogEvent(ok ? "SL_UPDATE" : "SL_UPDATE_FAIL",
            "RiskManagement",
            is_buy ? "BUY" : "SELL",
            volume,
            current_price,
            new_sl,
            tp,
            ret,
            desc,
            StringFormat("R=%.2f", r_multiple));
}

void TryProcessSignal(const datetime now, const datetime signal_bar, const bool is_new_signal_bar)
{
   if(signal_bar <= 0)
      return;

   int direction = 0;
   if(!DetectCrossSignal(is_new_signal_bar, direction))
      return;

   bool is_buy = (direction > 0);

   if(!CanTradeThisBar(signal_bar))
      return;

   if(IsCooldownBlocked(signal_bar))
   {
      LogEvent("ENTRY_SKIP",
               "CooldownAfterLoss",
               is_buy ? "BUY" : "SELL",
               0.0,
               0.0,
               0.0,
               0.0,
               0,
               "none",
               StringFormat("bars=%d", CooldownBarsAfterLoss));
      return;
   }

   if(!EntryFiltersPass(now, is_buy))
      return;

   ulong ticket = 0;
   long type = -1;
   double open_price = 0.0;
   double sl = 0.0;
   double tp = 0.0;
   double volume = 0.0;
   datetime open_time = 0;
   string comment = "";

   bool has_pos = GetStrategyPosition(ticket, type, open_price, sl, tp, volume, open_time, comment);
   if(!has_pos && HasAnyOpenPosition())
   {
      LogEvent("ENTRY_SKIP",
               "GlobalOnePositionRule",
               is_buy ? "BUY" : "SELL",
               0.0,
               0.0,
               0.0,
               0.0,
               0,
               "none",
               "another position already open");
      return;
   }

   if(has_pos)
   {
      bool pos_is_buy = (type == POSITION_TYPE_BUY);
      if(pos_is_buy == is_buy)
         return;

      if(!CloseStrategyPosition(ticket, "CrossReversal"))
         return;
   }

   if(HasAnyOpenPosition())
   {
      LogEvent("ENTRY_SKIP",
               "GlobalOnePositionRule",
               is_buy ? "BUY" : "SELL",
               0.0,
               0.0,
               0.0,
               0.0,
               0,
               "none",
               "position still open after reversal close");
      return;
   }

   double atr = 0.0;
   int atr_shift = UseBarCloseConfirmation ? 1 : 0;
   if(!ReadBufferValue(g_atr_handle, 0, atr_shift, atr) || atr <= 0.0)
      atr = GetStopDistancePrice();

   OpenTradeWithRetries(is_buy, atr, signal_bar);
}

int OnInit()
{
   string symbol_upper = ToUpperCopy(_Symbol);
   if(StringFind(symbol_upper, "XAUUSD") < 0)
      Print("Warning: This EA is designed for XAUUSD. Current symbol may not match planned behavior.");

   g_trade.SetExpertMagicNumber(EA_MAGIC_H1);
   g_trade.SetDeviationInPoints(30);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   ParseNewsCurrencies();
   InitLastTradeBarState();
   InitPersistentState();
   ResetExecStats();
   g_last_stop_update_time = 0;
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
            0,
            "none",
            StringFormat("SignalTF=%s EmaFast=%d EmaSlow=%d", EnumToString(SignalTF), EmaFast, EmaSlow));

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EmitExecSummary();
   LogEvent("DEINIT",
            IntegerToString(reason),
            "-",
            0.0,
            0.0,
            0.0,
            0.0,
            0,
            "none",
            "EA stop");

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

   ManageOpenPosition(now, is_new_signal_bar);
   TryProcessSignal(now, signal_bar, is_new_signal_bar);
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
   if(magic != EA_MAGIC_H1)
      return;

   long deal_type = HistoryDealGetInteger(deal_ticket, DEAL_TYPE);
   long deal_entry = HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
   double volume = HistoryDealGetDouble(deal_ticket, DEAL_VOLUME);
   double price = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
   double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);
   datetime deal_time = (datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME);

   string side = "OTHER";
   if(deal_type == DEAL_TYPE_BUY)
      side = "BUY";
   else if(deal_type == DEAL_TYPE_SELL)
      side = "SELL";

   string evt = (deal_entry == DEAL_ENTRY_IN) ? "DEAL_IN" : "DEAL_OUT";

   if(deal_entry == DEAL_ENTRY_OUT)
   {
      if(profit < 0.0)
         SaveLastLossCloseTime(deal_time);

      ulong pos_ticket = 0;
      long pos_type = -1;
      double pos_open_price = 0.0;
      double pos_sl = 0.0;
      double pos_tp = 0.0;
      double pos_volume = 0.0;
      datetime pos_open_time = 0;
      string pos_comment = "";
      if(!GetStrategyPosition(pos_ticket, pos_type, pos_open_price, pos_sl, pos_tp, pos_volume, pos_open_time, pos_comment))
      {
         g_partial_done_ticket = 0.0;
         if(StringLen(g_partial_done_ticket_key) > 0)
            GlobalVariableSet(g_partial_done_ticket_key, g_partial_done_ticket);
      }
   }

   LogEvent(evt,
            StringFormat("profit=%.2f", profit),
            side,
            volume,
            price,
            0.0,
            0.0,
            (int)result.retcode,
            result.comment,
            StringFormat("deal=%I64d", deal_ticket));
}

double OnTester()
{
   double pf = TesterStatistics(STAT_PROFIT_FACTOR);
   double dd = TesterStatistics(STAT_BALANCE_DDREL_PERCENT);
   double trades = TesterStatistics(STAT_TRADES);

   if(pf <= 0.0 || trades <= 0.0)
      return -1000.0;

   double score = pf;

   if(dd > 20.0)
      score -= (dd - 20.0) + 10.0;

   if(MinTradesForScore > 0 && trades < (double)MinTradesForScore)
   {
      double ratio = trades / (double)MinTradesForScore;
      if(trades <= 10.0)
         return -1000.0 + ratio;
      score = (pf * ratio) - 10.0;
   }

   return score;
}
