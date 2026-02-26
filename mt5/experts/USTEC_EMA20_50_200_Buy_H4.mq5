#property copyright "SMINDS"
#property version   "1.00"
#property strict
#property description "Buy-only EMA 20/50 cross EA with EMA 200 trend filter for USTEC H4."

#include <Trade/Trade.mqh>

input double InpLotSize = 1.0;

const int FAST_EMA_PERIOD = 20;
const int SLOW_EMA_PERIOD = 50;
const int FILTER_EMA_PERIOD = 200;
const ENUM_TIMEFRAMES STRATEGY_TIMEFRAME = PERIOD_H4;
const string STRATEGY_SYMBOL = "USTEC";
const ulong STRATEGY_MAGIC = 26022505;

CTrade g_trade;
int g_ema20_handle = INVALID_HANDLE;
int g_ema50_handle = INVALID_HANDLE;
int g_ema200_handle = INVALID_HANDLE;
datetime g_last_bar_time = 0;

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
   double min_volume = SymbolInfoDouble(STRATEGY_SYMBOL, SYMBOL_VOLUME_MIN);
   double max_volume = SymbolInfoDouble(STRATEGY_SYMBOL, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(STRATEGY_SYMBOL, SYMBOL_VOLUME_STEP);

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
   if(CopyTime(STRATEGY_SYMBOL, STRATEGY_TIMEFRAME, 0, 2, bars) != 2)
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

bool ReadClosedBarEmaPair(const int handle, double &current_closed_bar, double &previous_closed_bar)
{
   double values[];
   ArraySetAsSeries(values, true);
   if(CopyBuffer(handle, 0, 1, 2, values) != 2)
      return false;

   current_closed_bar = values[0];
   previous_closed_bar = values[1];
   return MathIsValidNumber(current_closed_bar) && MathIsValidNumber(previous_closed_bar);
}

bool ReadClosedBarClose(double &closed_bar_close)
{
   double closes[];
   ArraySetAsSeries(closes, true);
   if(CopyClose(STRATEGY_SYMBOL, STRATEGY_TIMEFRAME, 1, 1, closes) != 1)
      return false;

   closed_bar_close = closes[0];
   return MathIsValidNumber(closed_bar_close);
}

bool FindOpenBuyPosition(ulong &ticket)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong pos_ticket = PositionGetTicket(i);
      if(pos_ticket == 0 || !PositionSelectByTicket(pos_ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
      long type = PositionGetInteger(POSITION_TYPE);

      if(symbol == STRATEGY_SYMBOL && magic == STRATEGY_MAGIC && type == POSITION_TYPE_BUY)
      {
         ticket = pos_ticket;
         return true;
      }
   }

   return false;
}

int OnInit()
{
   if(_Symbol != STRATEGY_SYMBOL || _Period != STRATEGY_TIMEFRAME)
   {
      PrintFormat("Attach this EA to %s on %s timeframe.", STRATEGY_SYMBOL, EnumToString(STRATEGY_TIMEFRAME));
      return INIT_PARAMETERS_INCORRECT;
   }

   if(!SymbolSelect(STRATEGY_SYMBOL, true))
   {
      PrintFormat("Failed to select symbol %s.", STRATEGY_SYMBOL);
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber((long)STRATEGY_MAGIC);
   g_trade.SetTypeFillingBySymbol(STRATEGY_SYMBOL);
   g_trade.SetDeviationInPoints(30);

   g_ema20_handle = iMA(STRATEGY_SYMBOL, STRATEGY_TIMEFRAME, FAST_EMA_PERIOD, 0, MODE_EMA, PRICE_CLOSE);
   g_ema50_handle = iMA(STRATEGY_SYMBOL, STRATEGY_TIMEFRAME, SLOW_EMA_PERIOD, 0, MODE_EMA, PRICE_CLOSE);
   g_ema200_handle = iMA(STRATEGY_SYMBOL, STRATEGY_TIMEFRAME, FILTER_EMA_PERIOD, 0, MODE_EMA, PRICE_CLOSE);

   if(g_ema20_handle == INVALID_HANDLE || g_ema50_handle == INVALID_HANDLE || g_ema200_handle == INVALID_HANDLE)
   {
      Print("Failed to initialize EMA handles.");
      return INIT_FAILED;
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_ema20_handle != INVALID_HANDLE)
      IndicatorRelease(g_ema20_handle);
   if(g_ema50_handle != INVALID_HANDLE)
      IndicatorRelease(g_ema50_handle);
   if(g_ema200_handle != INVALID_HANDLE)
      IndicatorRelease(g_ema200_handle);
}

void OnTick()
{
   datetime bar_time = 0;
   if(!IsNewStrategyBar(bar_time))
      return;

   double ema20_current = 0.0;
   double ema20_previous = 0.0;
   double ema50_current = 0.0;
   double ema50_previous = 0.0;
   double ema200_current = 0.0;
   double ema200_previous = 0.0;
   double close_current = 0.0;

   if(!ReadClosedBarEmaPair(g_ema20_handle, ema20_current, ema20_previous))
      return;
   if(!ReadClosedBarEmaPair(g_ema50_handle, ema50_current, ema50_previous))
      return;
   if(!ReadClosedBarEmaPair(g_ema200_handle, ema200_current, ema200_previous))
      return;
   if(!ReadClosedBarClose(close_current))
      return;

   bool bullish_cross = (ema20_previous <= ema50_previous && ema20_current > ema50_current);
   bool bearish_cross = (ema20_previous >= ema50_previous && ema20_current < ema50_current);
   bool price_above_ema200 = (close_current > ema200_current);

   ulong buy_ticket = 0;
   bool has_open_buy = FindOpenBuyPosition(buy_ticket);

   if(has_open_buy && bearish_cross)
   {
      if(!g_trade.PositionClose(buy_ticket))
      {
         PrintFormat("Failed to close buy position #%I64u. Retcode=%d", buy_ticket, (int)g_trade.ResultRetcode());
      }
      return;
   }

   if(has_open_buy)
      return;

   if(!bullish_cross || !price_above_ema200)
      return;

   double volume = NormalizeVolume(InpLotSize);
   if(volume <= 0.0)
   {
      PrintFormat("Invalid lot size %.2f after normalization.", InpLotSize);
      return;
   }

   if(!g_trade.Buy(volume, STRATEGY_SYMBOL, 0.0, 0.0, 0.0, "EMA20x50 Buy"))
   {
      PrintFormat("Buy order failed. Retcode=%d", (int)g_trade.ResultRetcode());
   }
}


