#property copyright "Blissful Minds Inc."
#property version   "2.00"
#property strict

#include <Trade/Trade.mqh>

input double InpLotSize = 1.0;
input int InpFastEmaPeriod = 50;
input int InpSlowEmaPeriod = 75;
input int InpFilterEmaPeriod = 200;

const ulong ID_TAG = 94736251;

CTrade g_t;
int g_h_fast = INVALID_HANDLE;
int g_h_slow = INVALID_HANDLE;
int g_h_filter = INVALID_HANDLE;
datetime g_last_bar_time = 0;
ENUM_TIMEFRAMES g_tf = PERIOD_CURRENT;
bool g_startup_checked = false;
bool g_wait_filter_breakout = false;

int VolumeDigits(const double step)
{
   for(int d = 0; d <= 8; d++)
   {
      double scaled = step * MathPow(10.0, d);
      if(MathAbs(scaled - MathRound(scaled)) < 1e-8)
         return d;
   }
   return 8;
}

double NormalizeVolume(const double x)
{
   double min_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0 || min_volume <= 0.0 || max_volume <= 0.0)
      return 0.0;

   double clipped = MathMax(min_volume, MathMin(max_volume, x));
   double normalized = MathFloor(clipped / step) * step;
   return NormalizeDouble(normalized, VolumeDigits(step));
}

bool IsNewBar(datetime &bar_time)
{
   datetime bars[];
   ArraySetAsSeries(bars, true);
   if(CopyTime(_Symbol, g_tf, 0, 2, bars) != 2)
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

bool ReadClosedEmaPair(const int handle, double &current, double &previous)
{
   double values[];
   ArraySetAsSeries(values, true);
   if(CopyBuffer(handle, 0, 1, 2, values) != 2)
      return false;

   current = values[0];
   previous = values[1];
   return MathIsValidNumber(current) && MathIsValidNumber(previous);
}

bool ReadClosedClose(double &value)
{
   double closes[];
   ArraySetAsSeries(closes, true);
   if(CopyClose(_Symbol, g_tf, 1, 1, closes) != 1)
      return false;

   value = closes[0];
   return MathIsValidNumber(value);
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

      if(symbol == _Symbol && magic == ID_TAG && type == POSITION_TYPE_BUY)
      {
         ticket = pos_ticket;
         return true;
      }
   }

   return false;
}

void LogBarState(const datetime bar_time,
                 const double fast_current,
                 const double fast_previous,
                 const double slow_current,
                 const double slow_previous,
                 const double filter_current,
                 const double close_current,
                 const bool up_cross,
                 const bool down_cross,
                 const bool pass_filter,
                 const bool trend_up,
                 const bool has_buy)
{
   string ts = TimeToString(bar_time, TIME_DATE | TIME_MINUTES);
   PrintFormat(
      "TTR-X-v2 | bar=%s | fast=%.5f/%.5f slow=%.5f/%.5f filter=%.5f close=%.5f | up=%s down=%s pass=%s trendUp=%s hasBuy=%s waitFilter=%s startupChecked=%s",
      ts,
      fast_current,
      fast_previous,
      slow_current,
      slow_previous,
      filter_current,
      close_current,
      up_cross ? "true" : "false",
      down_cross ? "true" : "false",
      pass_filter ? "true" : "false",
      trend_up ? "true" : "false",
      has_buy ? "true" : "false",
      g_wait_filter_breakout ? "true" : "false",
      g_startup_checked ? "true" : "false"
   );
}

int OnInit()
{
   g_tf = (ENUM_TIMEFRAMES)_Period;

   if(InpFastEmaPeriod <= 0 || InpSlowEmaPeriod <= 0 || InpFilterEmaPeriod <= 0 || InpFastEmaPeriod >= InpSlowEmaPeriod)
   {
      Print("Invalid EMA parameters.");
      return INIT_PARAMETERS_INCORRECT;
   }

   PrintFormat(
      "TTR-X-v2 init | FastEMA=%d SlowEMA=%d FilterEMA=%d TF=%s",
      InpFastEmaPeriod,
      InpSlowEmaPeriod,
      InpFilterEmaPeriod,
      EnumToString(g_tf)
   );

   if(!SymbolSelect(_Symbol, true))
   {
      PrintFormat("Failed to select symbol %s.", _Symbol);
      return INIT_FAILED;
   }

   g_t.SetExpertMagicNumber((long)ID_TAG);
   g_t.SetTypeFillingBySymbol(_Symbol);
   g_t.SetDeviationInPoints(30);

   g_h_fast = iMA(_Symbol, g_tf, InpFastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_h_slow = iMA(_Symbol, g_tf, InpSlowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_h_filter = iMA(_Symbol, g_tf, InpFilterEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(g_h_fast == INVALID_HANDLE || g_h_slow == INVALID_HANDLE || g_h_filter == INVALID_HANDLE)
   {
      Print("Init failed.");
      return INIT_FAILED;
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_h_fast != INVALID_HANDLE)
      IndicatorRelease(g_h_fast);
   if(g_h_slow != INVALID_HANDLE)
      IndicatorRelease(g_h_slow);
   if(g_h_filter != INVALID_HANDLE)
      IndicatorRelease(g_h_filter);
}

void OnTick()
{
   datetime bar_time = 0;
   if(!IsNewBar(bar_time))
      return;

   double fast_current = 0.0;
   double fast_previous = 0.0;
   double slow_current = 0.0;
   double slow_previous = 0.0;
   double filter_current = 0.0;
   double filter_previous = 0.0;
   double close_current = 0.0;

   if(!ReadClosedEmaPair(g_h_fast, fast_current, fast_previous))
      return;
   if(!ReadClosedEmaPair(g_h_slow, slow_current, slow_previous))
      return;
   if(!ReadClosedEmaPair(g_h_filter, filter_current, filter_previous))
      return;
   if(!ReadClosedClose(close_current))
      return;

   bool up_cross = (fast_previous <= slow_previous && fast_current > slow_current);
   bool down_cross = (fast_previous >= slow_previous && fast_current < slow_current);
   bool pass_filter = (close_current > filter_current);
   bool trend_up = (fast_current > slow_current);

   ulong ticket = 0;
   bool has_buy = FindOpenBuyPosition(ticket);

   LogBarState(
      bar_time,
      fast_current,
      fast_previous,
      slow_current,
      slow_previous,
      filter_current,
      close_current,
      up_cross,
      down_cross,
      pass_filter,
      trend_up,
      has_buy
   );

   if(has_buy && down_cross)
   {
      PrintFormat("TTR-X-v2 | closing buy ticket=%I64u on down cross.", ticket);
      if(!g_t.PositionClose(ticket))
      {
         PrintFormat("Close failed. Retcode=%d", (int)g_t.ResultRetcode());
      }
      return;
   }

   if(has_buy)
      return;

   if(!g_startup_checked)
   {
      g_startup_checked = true;
      if(trend_up && !pass_filter)
      {
         g_wait_filter_breakout = true;
         Print("TTR-X-v2 | startup arm enabled: FastEMA already above SlowEMA while close is below FilterEMA. Waiting for close above FilterEMA.");
      }
      else
      {
         Print("TTR-X-v2 | startup arm not enabled.");
      }
   }

   if(g_wait_filter_breakout)
   {
      if(!trend_up)
      {
         g_wait_filter_breakout = false;
         Print("TTR-X-v2 | startup arm cancelled: FastEMA is no longer above SlowEMA.");
         return;
      }

      if(pass_filter)
      {
         double armed_volume = NormalizeVolume(InpLotSize);
         if(armed_volume <= 0.0)
         {
            PrintFormat("Invalid volume %.2f.", InpLotSize);
            return;
         }

         Print("TTR-X-v2 | startup armed entry triggered: close moved above FilterEMA.");
         if(!g_t.Buy(armed_volume, _Symbol, 0.0, 0.0, 0.0, "TTR-X-v2"))
         {
            PrintFormat("Entry failed. Retcode=%d", (int)g_t.ResultRetcode());
            return;
         }

         g_wait_filter_breakout = false;
         return;
      }

      Print("TTR-X-v2 | startup arm active: waiting for close above FilterEMA.");
      return;
   }

   if(!up_cross || !pass_filter)
   {
      Print("TTR-X-v2 | no entry: cross/filter condition not satisfied.");
      return;
   }

   double volume = NormalizeVolume(InpLotSize);
   if(volume <= 0.0)
   {
      PrintFormat("Invalid volume %.2f.", InpLotSize);
      return;
   }

   Print("TTR-X-v2 | regular entry: up-cross with close above FilterEMA.");
   if(!g_t.Buy(volume, _Symbol, 0.0, 0.0, 0.0, "TTR-X-v2"))
   {
      PrintFormat("Entry failed. Retcode=%d", (int)g_t.ResultRetcode());
   }
}

