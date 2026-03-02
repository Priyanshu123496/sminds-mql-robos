#property copyright "SMINDS"
#property version   "1.00"
#property strict
#property description "Research EA: EMA crossover with filter EMA, ADX/ATR/session filters, cooldown, and optional ATR SL/TP."

#include <Trade/Trade.mqh>

enum ENUM_TRADE_MODE
{
   TRADE_MODE_BUY_ONLY = 0,
   TRADE_MODE_BUY_SELL = 1
};

enum ENUM_SESSION_FILTER
{
   SESSION_FILTER_OFF = 0,
   SESSION_FILTER_ASIA = 1,
   SESSION_FILTER_LONDON = 2,
   SESSION_FILTER_NEWYORK = 3,
   SESSION_FILTER_LONDON_NEWYORK = 4
};

input double InpLotSize = 1.0;
input int InpFastEmaPeriod = 20;
input int InpSlowEmaPeriod = 50;
input int InpFilterEmaPeriod = 200;
input ENUM_TIMEFRAMES InpStrategyTimeframe = PERIOD_M15;
input ENUM_TRADE_MODE InpTradeMode = TRADE_MODE_BUY_SELL;
input bool InpUseAdxFilter = false;
input int InpAdxPeriod = 14;
input double InpMinAdx = 22.0;
input bool InpUseAtrFilter = false;
input int InpAtrPeriod = 14;
input double InpMinAtr = 1.0;
input ENUM_SESSION_FILTER InpSessionFilter = SESSION_FILTER_OFF;
input int InpCooldownBars = 0;
input bool InpUseSLTP = false;
input double InpSL_ATR_Mult = 2.0;
input double InpTP_ATR_Mult = 3.0;
input bool InpEvaluateOnEveryTick = false;
input long InpStrategyMagic = 0;

CTrade g_trade;
int g_fast_ema_handle = INVALID_HANDLE;
int g_slow_ema_handle = INVALID_HANDLE;
int g_filter_ema_handle = INVALID_HANDLE;
int g_adx_handle = INVALID_HANDLE;
int g_atr_handle = INVALID_HANDLE;
datetime g_last_bar_time = 0;
datetime g_last_trade_bar_time = 0;
ENUM_TIMEFRAMES g_strategy_timeframe = PERIOD_CURRENT;
long g_strategy_magic = 0;

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

long GenerateRandomMagic()
{
   int symbol_hash = 0;
   int symbol_len = StringLen(_Symbol);
   for(int i = 0; i < symbol_len; i++)
      symbol_hash = (symbol_hash * 31 + (int)StringGetCharacter(_Symbol, i)) & 0x7FFFFFFF;

   long seed = (long)TimeLocal() + (long)GetTickCount() + (long)ChartID() +
               (long)AccountInfoInteger(ACCOUNT_LOGIN) + (long)_Period + (long)symbol_hash;
   MathSrand((int)(seed & 0x7FFFFFFF));
   return (long)(10000000 + (MathRand() % 90000000));
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

bool GetCurrentStrategyBarTime(datetime &bar_time)
{
   datetime bars[];
   ArraySetAsSeries(bars, true);
   if(CopyTime(_Symbol, g_strategy_timeframe, 0, 1, bars) != 1)
      return false;
   bar_time = bars[0];
   return true;
}

bool ReadPair(const int handle, const int shift, double &current_value, double &previous_value)
{
   double values[];
   ArraySetAsSeries(values, true);
   if(CopyBuffer(handle, 0, shift, 2, values) != 2)
      return false;
   current_value = values[0];
   previous_value = values[1];
   return MathIsValidNumber(current_value) && MathIsValidNumber(previous_value);
}

bool ReadSingle(const int handle, const int shift, double &value)
{
   double values[];
   ArraySetAsSeries(values, true);
   if(CopyBuffer(handle, 0, shift, 1, values) != 1)
      return false;
   value = values[0];
   return MathIsValidNumber(value);
}

bool ReadClose(const int shift, double &value)
{
   double closes[];
   ArraySetAsSeries(closes, true);
   if(CopyClose(_Symbol, g_strategy_timeframe, shift, 1, closes) != 1)
      return false;
   value = closes[0];
   return MathIsValidNumber(value);
}

bool IsHourAllowed(const int hour, const int start_hour, const int end_hour)
{
   if(start_hour == end_hour)
      return true;

   if(start_hour < end_hour)
      return (hour >= start_hour && hour < end_hour);

   return (hour >= start_hour || hour < end_hour);
}

bool IsWithinSession(const datetime bar_time)
{
   if(InpSessionFilter == SESSION_FILTER_OFF)
      return true;

   int start_hour = 0;
   int end_hour = 24;
   switch(InpSessionFilter)
   {
      case SESSION_FILTER_ASIA:
         start_hour = 0;
         end_hour = 9;
         break;
      case SESSION_FILTER_LONDON:
         start_hour = 7;
         end_hour = 16;
         break;
      case SESSION_FILTER_NEWYORK:
         start_hour = 13;
         end_hour = 22;
         break;
      case SESSION_FILTER_LONDON_NEWYORK:
         start_hour = 7;
         end_hour = 22;
         break;
      default:
         return true;
   }

   MqlDateTime dt;
   TimeToStruct(bar_time, dt);
   return IsHourAllowed(dt.hour, start_hour, end_hour);
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
         return true;
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

void BuildStops(const bool is_buy, const double atr_value, double &sl, double &tp)
{
   sl = 0.0;
   tp = 0.0;
   if(!InpUseSLTP || atr_value <= 0.0)
      return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(!MathIsValidNumber(ask) || !MathIsValidNumber(bid) || ask <= 0.0 || bid <= 0.0)
      return;

   if(is_buy)
   {
      sl = NormalizeDouble(ask - InpSL_ATR_Mult * atr_value, digits);
      tp = NormalizeDouble(ask + InpTP_ATR_Mult * atr_value, digits);
   }
   else
   {
      sl = NormalizeDouble(bid + InpSL_ATR_Mult * atr_value, digits);
      tp = NormalizeDouble(bid - InpTP_ATR_Mult * atr_value, digits);
   }
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

   if(InpFastEmaPeriod <= 0 || InpSlowEmaPeriod <= 0 || InpFilterEmaPeriod <= 0)
   {
      Print("EMA periods must be positive.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpFastEmaPeriod >= InpSlowEmaPeriod)
   {
      Print("InpFastEmaPeriod must be smaller than InpSlowEmaPeriod.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpUseAdxFilter && (InpAdxPeriod <= 0 || InpMinAdx < 0.0))
   {
      Print("Invalid ADX filter parameters.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpUseAtrFilter && (InpAtrPeriod <= 0 || InpMinAtr < 0.0))
   {
      Print("Invalid ATR filter parameters.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpUseSLTP && (InpAtrPeriod <= 0 || InpSL_ATR_Mult <= 0.0 || InpTP_ATR_Mult <= 0.0))
   {
      Print("Invalid ATR SL/TP parameters.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpCooldownBars < 0)
   {
      Print("InpCooldownBars must be zero or positive.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpStrategyMagic < 0)
   {
      Print("InpStrategyMagic must be zero (auto) or positive.");
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

   g_fast_ema_handle = iMA(_Symbol, g_strategy_timeframe, InpFastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_slow_ema_handle = iMA(_Symbol, g_strategy_timeframe, InpSlowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_filter_ema_handle = iMA(_Symbol, g_strategy_timeframe, InpFilterEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(InpUseAdxFilter)
      g_adx_handle = iADX(_Symbol, g_strategy_timeframe, InpAdxPeriod);
   if(InpUseAtrFilter || InpUseSLTP)
      g_atr_handle = iATR(_Symbol, g_strategy_timeframe, InpAtrPeriod);

   if(g_fast_ema_handle == INVALID_HANDLE || g_slow_ema_handle == INVALID_HANDLE || g_filter_ema_handle == INVALID_HANDLE)
   {
      Print("Failed to initialize EMA handles.");
      return INIT_FAILED;
   }
   if(InpUseAdxFilter && g_adx_handle == INVALID_HANDLE)
   {
      Print("Failed to initialize ADX handle.");
      return INIT_FAILED;
   }
   if((InpUseAtrFilter || InpUseSLTP) && g_atr_handle == INVALID_HANDLE)
   {
      Print("Failed to initialize ATR handle.");
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
   if(g_filter_ema_handle != INVALID_HANDLE)
      IndicatorRelease(g_filter_ema_handle);
   if(g_adx_handle != INVALID_HANDLE)
      IndicatorRelease(g_adx_handle);
   if(g_atr_handle != INVALID_HANDLE)
      IndicatorRelease(g_atr_handle);
}

void OnTick()
{
   int shift = 0;
   datetime bar_time = 0;
   if(!InpEvaluateOnEveryTick)
   {
      if(!IsNewStrategyBar(bar_time))
         return;
      shift = 1;
   }
   else
   {
      if(!GetCurrentStrategyBarTime(bar_time))
         return;
      shift = 0;
   }

   if(!IsWithinSession(bar_time))
      return;
   if(!IsCooldownComplete(bar_time))
      return;

   double fast_current = 0.0;
   double fast_previous = 0.0;
   double slow_current = 0.0;
   double slow_previous = 0.0;
   double filter_current = 0.0;
   double close_value = 0.0;
   double adx_value = 0.0;
   double atr_value = 0.0;

   if(!ReadPair(g_fast_ema_handle, shift, fast_current, fast_previous))
      return;
   if(!ReadPair(g_slow_ema_handle, shift, slow_current, slow_previous))
      return;
   if(!ReadSingle(g_filter_ema_handle, shift, filter_current))
      return;
   if(!ReadClose(shift, close_value))
      return;

   bool bullish_cross = (fast_previous <= slow_previous && fast_current > slow_current);
   bool bearish_cross = (fast_previous >= slow_previous && fast_current < slow_current);
   if(!bullish_cross && !bearish_cross)
      return;

   if(InpUseAdxFilter)
   {
      if(!ReadSingle(g_adx_handle, shift, adx_value))
         return;
      if(adx_value < InpMinAdx)
         return;
   }

   if(InpUseAtrFilter || InpUseSLTP)
   {
      if(!ReadSingle(g_atr_handle, shift, atr_value))
         return;
   }

   if(InpUseAtrFilter && atr_value < InpMinAtr)
      return;

   bool price_above_filter = (close_value > filter_current);
   bool price_below_filter = (close_value < filter_current);

   double volume = NormalizeVolume(InpLotSize);
   if(volume <= 0.0)
      return;

   if(bullish_cross && price_above_filter)
   {
      if(!CloseOpenPositionsByType(POSITION_TYPE_SELL))
         return;
      if(HasOpenPositionType(POSITION_TYPE_BUY))
         return;

      double sl = 0.0;
      double tp = 0.0;
      BuildStops(true, atr_value, sl, tp);
      string buy_comment = StringFormat("EMA%dx%d/F%d Buy", InpFastEmaPeriod, InpSlowEmaPeriod, InpFilterEmaPeriod);
      if(g_trade.Buy(volume, _Symbol, 0.0, sl, tp, buy_comment))
         g_last_trade_bar_time = bar_time;
      return;
   }

   if(InpTradeMode == TRADE_MODE_BUY_SELL && bearish_cross && price_below_filter)
   {
      if(!CloseOpenPositionsByType(POSITION_TYPE_BUY))
         return;
      if(HasOpenPositionType(POSITION_TYPE_SELL))
         return;

      double sl = 0.0;
      double tp = 0.0;
      BuildStops(false, atr_value, sl, tp);
      string sell_comment = StringFormat("EMA%dx%d/F%d Sell", InpFastEmaPeriod, InpSlowEmaPeriod, InpFilterEmaPeriod);
      if(g_trade.Sell(volume, _Symbol, 0.0, sl, tp, sell_comment))
         g_last_trade_bar_time = bar_time;
      return;
   }

   if(InpTradeMode == TRADE_MODE_BUY_ONLY && bearish_cross)
      CloseOpenPositionsByType(POSITION_TYPE_BUY);
}
