#property copyright "Bliss Minds Inc."
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input double InpP1 = 1.0;
input int InpP2 = 709;
input int InpP3 = 1899;
input int InpP4 = 4452;
input ENUM_TIMEFRAMES InpP5 = PERIOD_H4;

const ulong ID_TAG = 94736251;

CTrade g_t;
int g_h1 = INVALID_HANDLE;
int g_h2 = INVALID_HANDLE;
int g_h3 = INVALID_HANDLE;
datetime g_bt = 0;
ENUM_TIMEFRAMES g_tf = PERIOD_H4;
int g_p2 = 0;
int g_p3 = 0;
int g_p4 = 0;

int Dp(const double s)
{
   for(int d = 0; d <= 8; d++)
   {
      double v = s * MathPow(10.0, d);
      if(MathAbs(v - MathRound(v)) < 1e-8)
         return d;
   }
   return 8;
}

double Nv(const double x)
{
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(st <= 0.0 || mn <= 0.0 || mx <= 0.0)
      return 0.0;

   double c = MathMax(mn, MathMin(mx, x));
   double n = MathFloor(c / st) * st;
   return NormalizeDouble(n, Dp(st));
}

int Dx(const int code, const int a, const int b, const int c)
{
   if(b <= 0)
      return -1;

   int t = (code ^ c);
   if(t <= 0 || (t % b) != 0)
      return -1;

   int p = t / b - a;
   if(p <= 0)
      return -1;

   return p;
}

bool Nb(datetime &t)
{
   datetime b[];
   ArraySetAsSeries(b, true);
   if(CopyTime(_Symbol, g_tf, 0, 2, b) != 2)
      return false;

   t = b[0];

   if(g_bt == 0)
   {
      g_bt = t;
      return false;
   }

   if(t != g_bt)
   {
      g_bt = t;
      return true;
   }

   return false;
}

bool Rp(const int h, double &c, double &p)
{
   double v[];
   ArraySetAsSeries(v, true);
   if(CopyBuffer(h, 0, 1, 2, v) != 2)
      return false;

   c = v[0];
   p = v[1];
   return MathIsValidNumber(c) && MathIsValidNumber(p);
}

bool Rc(double &x)
{
   double c[];
   ArraySetAsSeries(c, true);
   if(CopyClose(_Symbol, g_tf, 1, 1, c) != 1)
      return false;

   x = c[0];
   return MathIsValidNumber(x);
}

bool Fb(ulong &tk)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ptk = PositionGetTicket(i);
      if(ptk == 0 || !PositionSelectByTicket(ptk))
         continue;

      string s = PositionGetString(POSITION_SYMBOL);
      ulong m = (ulong)PositionGetInteger(POSITION_MAGIC);
      long ty = PositionGetInteger(POSITION_TYPE);

      if(s == _Symbol && m == ID_TAG && ty == POSITION_TYPE_BUY)
      {
         tk = ptk;
         return true;
      }
   }

   return false;
}

int OnInit()
{
   g_tf = InpP5;
   if(g_tf == PERIOD_CURRENT)
      g_tf = (ENUM_TIMEFRAMES)_Period;

   if(_Period != g_tf)
   {
      PrintFormat("Attach to %s timeframe.", EnumToString(g_tf));
      return INIT_PARAMETERS_INCORRECT;
   }

   g_p2 = Dx(InpP2, 11, 17, 913);
   g_p3 = Dx(InpP3, 17, 19, 1291);
   g_p4 = Dx(InpP4, 23, 29, 2087);

   if(g_p2 <= 0 || g_p3 <= 0 || g_p4 <= 0)
   {
      Print("Invalid parameters.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(g_p2 >= g_p3)
   {
      Print("Invalid parameters.");
      return INIT_PARAMETERS_INCORRECT;
   }

   PrintFormat("Decoded periods -> FastEMA=%d SlowEMA=%d FilterEMA=%d", g_p2, g_p3, g_p4);

   if(!SymbolSelect(_Symbol, true))
   {
      PrintFormat("Failed to select symbol %s.", _Symbol);
      return INIT_FAILED;
   }

   g_t.SetExpertMagicNumber((long)ID_TAG);
   g_t.SetTypeFillingBySymbol(_Symbol);
   g_t.SetDeviationInPoints(30);

   g_h1 = iMA(_Symbol, g_tf, g_p2, 0, MODE_EMA, PRICE_CLOSE);
   g_h2 = iMA(_Symbol, g_tf, g_p3, 0, MODE_EMA, PRICE_CLOSE);
   g_h3 = iMA(_Symbol, g_tf, g_p4, 0, MODE_EMA, PRICE_CLOSE);

   if(g_h1 == INVALID_HANDLE || g_h2 == INVALID_HANDLE || g_h3 == INVALID_HANDLE)
   {
      Print("Init failed.");
      return INIT_FAILED;
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_h1 != INVALID_HANDLE)
      IndicatorRelease(g_h1);
   if(g_h2 != INVALID_HANDLE)
      IndicatorRelease(g_h2);
   if(g_h3 != INVALID_HANDLE)
      IndicatorRelease(g_h3);
}

void OnTick()
{
   datetime t = 0;
   if(!Nb(t))
      return;

   double a_c = 0.0;
   double a_p = 0.0;
   double b_c = 0.0;
   double b_p = 0.0;
   double f_c = 0.0;
   double f_p = 0.0;
   double px = 0.0;

   if(!Rp(g_h1, a_c, a_p))
      return;
   if(!Rp(g_h2, b_c, b_p))
      return;
   if(!Rp(g_h3, f_c, f_p))
      return;
   if(!Rc(px))
      return;

   bool up = (a_p <= b_p && a_c > b_c);
   bool dn = (a_p >= b_p && a_c < b_c);
   bool pass = (px > f_c);

   ulong tk = 0;
   bool has = Fb(tk);

   if(has && dn)
   {
      if(!g_t.PositionClose(tk))
      {
         PrintFormat("Close failed. Retcode=%d", (int)g_t.ResultRetcode());
      }
      return;
   }

   if(has)
      return;

   if(!up || !pass)
      return;

   double vol = Nv(InpP1);
   if(vol <= 0.0)
   {
      PrintFormat("Invalid volume %.2f.", InpP1);
      return;
   }

   if(!g_t.Buy(vol, _Symbol, 0.0, 0.0, 0.0, "TTR-X"))
   {
      PrintFormat("Entry failed. Retcode=%d", (int)g_t.ResultRetcode());
   }
}
