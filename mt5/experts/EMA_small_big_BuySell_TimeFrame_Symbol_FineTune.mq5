#property copyright "SMINDS"
#property version   "1.00"
#property strict
#property description "EMA crossover buy/sell EA for any symbol and timeframe with optional tuning filters."

#include <Trade/Trade.mqh>

input double InpLotSize = 1.0;
input int InpFastEmaPeriod = 9;
input int InpSlowEmaPeriod = 15;
input ENUM_TIMEFRAMES InpStrategyTimeframe = PERIOD_H4;
input long InpStrategyMagic = 16456675;
input bool InpEvaluateOnEveryTick = false;
input bool InpUseTrendFilter = false;
input int InpTrendEmaPeriod = 200;
input bool InpUseAdxFilter = false;
input int InpAdxPeriod = 14;
input double InpMinAdx = 22.0;
input bool InpUseEmaDistanceFilter = false;
input double InpMinEmaDistancePoints = 0.0;
input bool InpRequireCandleConfirmation = false;
input int InpCooldownBars = 0;
input bool InpUseTradingSessionFilter = false;
input int InpSessionStartHour = 0;
input int InpSessionEndHour = 24;

CTrade g_trade;
int g_fast_ema_handle = INVALID_HANDLE;
int g_slow_ema_handle = INVALID_HANDLE;
int g_trend_ema_handle = INVALID_HANDLE;
int g_adx_handle = INVALID_HANDLE;
datetime g_last_bar_time = 0;
ENUM_TIMEFRAMES g_strategy_timeframe = PERIOD_CURRENT;
long g_strategy_magic = 0;
datetime g_last_trade_bar_time = 0;

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

double NormalizeVolume(const double volume)
{
   double min_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0 || min_volume <= 0.0 || max_volume <= 0.0)
      return 0.0;

   double clipped = MathMax(min_volume, MathMin(max_volume, volume));
   double normalized = MathFloor(clipped / step) * step;
   int digits = VolumeDigits(step);
   return NormalizeDouble(normalized, digits);
}

bool IsNewStrategyBar(datetime &bar_time)
{
   datetime bars[];
   ArraySetAsSeries(bars, true);
   if(CopyTime(_Symbol, g_strategy_timeframe, 0, 2, bars) != 2)
      return false;

   bar_time = bars[0];

   if(g_last_bar_time == 0)
   {
      g_last_bar_time = bar_time;
      return false;
   }

   if(bar_time != g_last_bar_time)
   {
      g_last_bar_time = bar_time;
      return true;
   }

   return false;
}

bool ReadEmaPair(const int handle, const int current_shift, double &current_value, double &previous_value)
{
   double values[];
   ArraySetAsSeries(values, true);
   if(CopyBuffer(handle, 0, current_shift, 2, values) != 2)
      return false;

   current_value = values[0];
   previous_value = values[1];
   return MathIsValidNumber(current_value) && MathIsValidNumber(previous_value);
}

bool ReadEmaValue(const int handle, const int shift, double &value)
{
   double values[];
   ArraySetAsSeries(values, true);
   if(CopyBuffer(handle, 0, shift, 1, values) != 1)
      return false;

   value = values[0];
   return MathIsValidNumber(value);
}

bool ReadAdxValue(const int handle, const int shift, double &value)
{
   double values[];
   ArraySetAsSeries(values, true);
   if(CopyBuffer(handle, 0, shift, 1, values) != 1)
      return false;

   value = values[0];
   return MathIsValidNumber(value);
}

bool ReadCloseValue(const int shift, double &value)
{
   double closes[];
   ArraySetAsSeries(closes, true);
   if(CopyClose(_Symbol, g_strategy_timeframe, shift, 1, closes) != 1)
      return false;

   value = closes[0];
   return MathIsValidNumber(value);
}

bool GetCurrentStrategyBarTime(datetime &bar_time)
{
   datetime bars[];
   ArraySetAsSeries(bars, true);
   if(CopyTime(_Symbol, g_strategy_timeframe, 0, 1, bars) != 1)
      return false;

   bar_time = bars[0];
   return true;
}

bool IsHourAllowed(const int hour, const int start_hour, const int end_hour)
{
   if(start_hour == end_hour)
      return true;

   if(start_hour < end_hour)
      return (hour >= start_hour && hour < end_hour);

   return (hour >= start_hour || hour < end_hour);
}

bool IsWithinTradingSession(const datetime bar_time)
{
   if(!InpUseTradingSessionFilter)
      return true;

   MqlDateTime dt;
   TimeToStruct(bar_time, dt);
   return IsHourAllowed(dt.hour, InpSessionStartHour, InpSessionEndHour);
}

bool IsCooldownComplete(const datetime current_bar_time)
{
   if(InpCooldownBars <= 0 || g_last_trade_bar_time == 0)
      return true;

   int shift_now = iBarShift(_Symbol, g_strategy_timeframe, current_bar_time, true);
   int shift_last_trade = iBarShift(_Symbol, g_strategy_timeframe, g_last_trade_bar_time, true);
   if(shift_now < 0 || shift_last_trade < 0)
      return true;

   int bars_elapsed = shift_last_trade - shift_now;
   return (bars_elapsed >= InpCooldownBars);
}

long GenerateRandomMagic()
{
   // Build a seed from runtime context so multiple charts are unlikely to collide.
   int symbol_hash = 0;
   int symbol_len = StringLen(_Symbol);
   for(int i = 0; i < symbol_len; i++)
      symbol_hash = (symbol_hash * 31 + (int)StringGetCharacter(_Symbol, i)) & 0x7FFFFFFF;

   long seed = (long)TimeLocal() + (long)GetTickCount() + (long)ChartID() +
               (long)AccountInfoInteger(ACCOUNT_LOGIN) + (long)_Period + (long)symbol_hash;
   MathSrand((int)(seed & 0x7FFFFFFF));

   // Use 8-digit positive magic numbers by default.
   return (long)(10000000 + (MathRand() % 90000000));
}

bool HasOpenPositionType(const long position_type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pos_ticket = PositionGetTicket(i);
      if(pos_ticket == 0 || !PositionSelectByTicket(pos_ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      long magic = PositionGetInteger(POSITION_MAGIC);
      long type = PositionGetInteger(POSITION_TYPE);

      if(symbol == _Symbol && magic == g_strategy_magic && type == position_type)
      {
         return true;
      }
   }

   return false;
}

bool CloseOpenPositionsByType(const long position_type)
{
   bool all_closed = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pos_ticket = PositionGetTicket(i);
      if(pos_ticket == 0 || !PositionSelectByTicket(pos_ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      long magic = PositionGetInteger(POSITION_MAGIC);
      long type = PositionGetInteger(POSITION_TYPE);

      if(symbol != _Symbol || magic != g_strategy_magic || type != position_type)
         continue;

      if(!g_trade.PositionClose(pos_ticket))
      {
         all_closed = false;
         PrintFormat("Failed to close position #%I64u. Retcode=%d", pos_ticket, (int)g_trade.ResultRetcode());
      }
   }

   return all_closed;
}

int OnInit()
{
   g_strategy_timeframe = InpStrategyTimeframe;
   if(g_strategy_timeframe == PERIOD_CURRENT)
      g_strategy_timeframe = (ENUM_TIMEFRAMES)_Period;

   if(_Period != g_strategy_timeframe)
   {
      PrintFormat("Attach this EA to %s timeframe.", EnumToString(g_strategy_timeframe));
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpFastEmaPeriod <= 0 || InpSlowEmaPeriod <= 0)
   {
      Print("EMA periods must be positive.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpFastEmaPeriod >= InpSlowEmaPeriod)
   {
      Print("InpFastEmaPeriod must be smaller than InpSlowEmaPeriod.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpUseTrendFilter && InpTrendEmaPeriod <= 0)
   {
      Print("InpTrendEmaPeriod must be positive when trend filter is enabled.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpUseAdxFilter && InpAdxPeriod <= 0)
   {
      Print("InpAdxPeriod must be positive when ADX filter is enabled.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpUseAdxFilter && InpMinAdx < 0.0)
   {
      Print("InpMinAdx must be non-negative when ADX filter is enabled.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpUseEmaDistanceFilter && InpMinEmaDistancePoints < 0.0)
   {
      Print("InpMinEmaDistancePoints must be non-negative.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpCooldownBars < 0)
   {
      Print("InpCooldownBars must be zero or positive.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpUseTradingSessionFilter &&
      (InpSessionStartHour < 0 || InpSessionStartHour > 23 || InpSessionEndHour < 0 || InpSessionEndHour > 24))
   {
      Print("InpSessionStartHour must be 0..23 and InpSessionEndHour must be 0..24.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpStrategyMagic < 0)
   {
      Print("InpStrategyMagic must be zero (auto) or a positive value.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpStrategyMagic > 0)
      g_strategy_magic = InpStrategyMagic;
   else
      g_strategy_magic = GenerateRandomMagic();

   if(!SymbolSelect(_Symbol, true))
   {
      PrintFormat("Failed to select symbol %s.", _Symbol);
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber(g_strategy_magic);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetDeviationInPoints(30);

   if(InpStrategyMagic == 0)
      PrintFormat("InpStrategyMagic=0, auto-generated magic=%I64d", g_strategy_magic);
   else
      PrintFormat("Using manual magic=%I64d", g_strategy_magic);

   g_fast_ema_handle = iMA(_Symbol, g_strategy_timeframe, InpFastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_slow_ema_handle = iMA(_Symbol, g_strategy_timeframe, InpSlowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(InpUseTrendFilter)
      g_trend_ema_handle = iMA(_Symbol, g_strategy_timeframe, InpTrendEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(InpUseAdxFilter)
      g_adx_handle = iADX(_Symbol, g_strategy_timeframe, InpAdxPeriod);

   if(g_fast_ema_handle == INVALID_HANDLE || g_slow_ema_handle == INVALID_HANDLE)
   {
      Print("Failed to initialize EMA handles.");
      return INIT_FAILED;
   }

   if(InpUseTrendFilter && g_trend_ema_handle == INVALID_HANDLE)
   {
      Print("Failed to initialize trend EMA handle.");
      return INIT_FAILED;
   }

   if(InpUseAdxFilter && g_adx_handle == INVALID_HANDLE)
   {
      Print("Failed to initialize ADX handle.");
      return INIT_FAILED;
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_fast_ema_handle != INVALID_HANDLE)
      IndicatorRelease(g_fast_ema_handle);
   if(g_slow_ema_handle != INVALID_HANDLE)
      IndicatorRelease(g_slow_ema_handle);
   if(g_trend_ema_handle != INVALID_HANDLE)
      IndicatorRelease(g_trend_ema_handle);
   if(g_adx_handle != INVALID_HANDLE)
      IndicatorRelease(g_adx_handle);
}

void OnTick()
{
   int ema_shift = 0;
   datetime current_bar_time = 0;
   if(!InpEvaluateOnEveryTick)
   {
      if(!IsNewStrategyBar(current_bar_time))
         return;
      // Open-bar mode: use closed candles only.
      ema_shift = 1;
   }
   else
   {
      if(!GetCurrentStrategyBarTime(current_bar_time))
         return;
   }

   double fast_ema_current = 0.0;
   double fast_ema_previous = 0.0;
   double slow_ema_current = 0.0;
   double slow_ema_previous = 0.0;
   double trend_ema_current = 0.0;
   double adx_current = 0.0;
   double close_value = 0.0;

   if(!ReadEmaPair(g_fast_ema_handle, ema_shift, fast_ema_current, fast_ema_previous))
      return;
   if(!ReadEmaPair(g_slow_ema_handle, ema_shift, slow_ema_current, slow_ema_previous))
      return;

   bool bullish_cross = (fast_ema_previous <= slow_ema_previous && fast_ema_current > slow_ema_current);
   bool bearish_cross = (fast_ema_previous >= slow_ema_previous && fast_ema_current < slow_ema_current);

   if(!bullish_cross && !bearish_cross)
      return;

   if(!IsWithinTradingSession(current_bar_time))
      return;

   if(!IsCooldownComplete(current_bar_time))
      return;

   if(InpUseEmaDistanceFilter)
   {
      double distance_points = MathAbs(fast_ema_current - slow_ema_current) / _Point;
      if(distance_points < InpMinEmaDistancePoints)
         return;
   }

   if(InpUseAdxFilter)
   {
      if(!ReadAdxValue(g_adx_handle, ema_shift, adx_current))
         return;

      if(adx_current < InpMinAdx)
         return;
   }

   bool needs_close_price = (InpUseTrendFilter || InpRequireCandleConfirmation);
   if(needs_close_price && !ReadCloseValue(ema_shift, close_value))
      return;

   if(InpUseTrendFilter)
   {
      if(!ReadEmaValue(g_trend_ema_handle, ema_shift, trend_ema_current))
         return;

      if(bullish_cross && close_value <= trend_ema_current)
         return;
      if(bearish_cross && close_value >= trend_ema_current)
         return;
   }

   if(InpRequireCandleConfirmation)
   {
      if(bullish_cross && (close_value <= fast_ema_current || close_value <= slow_ema_current))
         return;
      if(bearish_cross && (close_value >= fast_ema_current || close_value >= slow_ema_current))
         return;
   }

   double volume = NormalizeVolume(InpLotSize);
   if(volume <= 0.0)
   {
      PrintFormat("Invalid lot size %.2f after normalization.", InpLotSize);
      return;
   }

   if(bullish_cross)
   {
      if(!CloseOpenPositionsByType(POSITION_TYPE_SELL))
         return;

      if(HasOpenPositionType(POSITION_TYPE_BUY))
         return;

      string buy_comment = StringFormat("EMA%dx%d Buy", InpFastEmaPeriod, InpSlowEmaPeriod);
      if(!g_trade.Buy(volume, _Symbol, 0.0, 0.0, 0.0, buy_comment))
      {
         PrintFormat("Buy order failed. Retcode=%d", (int)g_trade.ResultRetcode());
      }
      else
      {
         g_last_trade_bar_time = current_bar_time;
      }
      return;
   }

   if(!CloseOpenPositionsByType(POSITION_TYPE_BUY))
      return;

   if(HasOpenPositionType(POSITION_TYPE_SELL))
      return;

   string sell_comment = StringFormat("EMA%dx%d Sell", InpFastEmaPeriod, InpSlowEmaPeriod);
   if(!g_trade.Sell(volume, _Symbol, 0.0, 0.0, 0.0, sell_comment))
   {
      PrintFormat("Sell order failed. Retcode=%d", (int)g_trade.ResultRetcode());
   }
   else
   {
      g_last_trade_bar_time = current_bar_time;
   }
}
