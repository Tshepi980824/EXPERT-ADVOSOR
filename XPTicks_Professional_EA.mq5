#property strict
#property version   "1.00"
#property description "XPTicks professional EA scaffold with risk controls, filters, and monitoring"

#include <Trade/Trade.mqh>

CTrade trade;

input long   InpMagicNumber                  = 980824;
input bool   InpEnableLongs                  = true;
input bool   InpEnableShorts                 = true;

// Risk architecture
input double InpRiskPerTradePct              = 0.50;
input double InpDailyDrawdownLimitPct        = 3.00;
input double InpWeeklyDrawdownLimitPct       = 6.00;
input int    InpMaxConcurrentPositions       = 1;
input int    InpMaxSpreadPoints              = 25;
input int    InpMaxSlippagePoints            = 20;
input int    InpMaxRetries                   = 2;
input bool   InpBlockHighVolatilitySpikes    = true;
input double InpMaxAtrMultiplierVsMedian     = 2.0;

// Signal quality and regime filters
input int    InpFastMA                       = 20;
input int    InpSlowMA                       = 50;
input int    InpRsiPeriod                    = 14;
input double InpRsiLongThreshold             = 55.0;
input double InpRsiShortThreshold            = 45.0;
input int    InpAtrPeriod                    = 14;
input int    InpMinTickVolume                = 100;
input int    InpSessionStartHour             = 7;
input int    InpSessionEndHour               = 20;

// Position management
input double InpAtrSLMultiplier              = 1.5;
input double InpAtrTPMultiplier              = 3.0;
input double InpBreakEvenR                   = 1.0;
input double InpTrailStartR                  = 1.5;
input double InpTrailStepR                   = 0.5;
input bool   InpEnablePartialClose           = true;
input double InpPartialCloseAtR              = 1.2;
input double InpPartialClosePct              = 0.50;
input int    InpMaxBarsInTrade               = 30;

// Portfolio and protection controls
input int    InpMaxSameCurrencyExposure      = 2;
input int    InpMaxConsecutiveLosses         = 4;
input int    InpHealthLogSeconds             = 60;

int g_fastMaHandle = INVALID_HANDLE;
int g_slowMaHandle = INVALID_HANDLE;
int g_rsiHandle    = INVALID_HANDLE;
int g_atrHandle    = INVALID_HANDLE;

double g_dayStartEquity = 0.0;
double g_weekStartEquity = 0.0;
int g_dayOfYear = -1;
int g_weekIndex = -1;
int g_consecutiveLosses = 0;
bool g_autoDisabled = false;

int OnInit()
{
   g_fastMaHandle = iMA(_Symbol, _Period, InpFastMA, 0, MODE_EMA, PRICE_CLOSE);
   g_slowMaHandle = iMA(_Symbol, _Period, InpSlowMA, 0, MODE_EMA, PRICE_CLOSE);
   g_rsiHandle    = iRSI(_Symbol, _Period, InpRsiPeriod, PRICE_CLOSE);
   g_atrHandle    = iATR(_Symbol, _Period, InpAtrPeriod);

   if(g_fastMaHandle == INVALID_HANDLE || g_slowMaHandle == INVALID_HANDLE || g_rsiHandle == INVALID_HANDLE || g_atrHandle == INVALID_HANDLE)
      return(INIT_FAILED);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpMaxSlippagePoints);

   ResetDayWeekBaselines();
   EventSetTimer(InpHealthLogSeconds);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(g_fastMaHandle != INVALID_HANDLE) IndicatorRelease(g_fastMaHandle);
   if(g_slowMaHandle != INVALID_HANDLE) IndicatorRelease(g_slowMaHandle);
   if(g_rsiHandle != INVALID_HANDLE) IndicatorRelease(g_rsiHandle);
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   EventKillTimer();
}

void OnTimer()
{
   PrintFormat("[XPTicks Health] disabled=%s dayDD=%.2f%% weekDD=%.2f%% spreadPts=%.1f openPos=%d losses=%d",
               g_autoDisabled ? "true" : "false",
               CurrentDayDrawdownPct(),
               CurrentWeekDrawdownPct(),
               CurrentSpreadPoints(),
               CountOpenPositionsForSymbol(),
               g_consecutiveLosses);
}

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong deal = trans.deal;
   if(deal == 0)
      return;

   if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagicNumber)
      return;

   if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
      return;

   long entryType = HistoryDealGetInteger(deal, DEAL_ENTRY);
   if(entryType != DEAL_ENTRY_OUT)
      return;

   double profit = HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP) + HistoryDealGetDouble(deal, DEAL_COMMISSION);
   if(profit < 0.0)
      g_consecutiveLosses++;
   else if(profit > 0.0)
      g_consecutiveLosses = 0;

   if(g_consecutiveLosses >= InpMaxConsecutiveLosses)
      g_autoDisabled = true;
}

void OnTick()
{
   ResetDayWeekBaselines();
   ManageOpenPositions();

   if(g_autoDisabled)
      return;

   if(!IsTradingAllowed())
      return;

   int signal = EntrySignal();
   if(signal == 0)
      return;

   if(CountOpenPositionsForSymbol() >= InpMaxConcurrentPositions)
      return;

   if(!PassesPortfolioExposureFilter(signal))
      return;

   PlaceOrderBySignal(signal);
}

bool IsTradingAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;

   if(CurrentSpreadPoints() > InpMaxSpreadPoints)
      return false;

   if(!PassesSessionFilter())
      return false;

   if(CurrentDayDrawdownPct() >= InpDailyDrawdownLimitPct)
   {
      g_autoDisabled = true;
      return false;
   }

   if(CurrentWeekDrawdownPct() >= InpWeeklyDrawdownLimitPct)
   {
      g_autoDisabled = true;
      return false;
   }

   if(InpBlockHighVolatilitySpikes && IsVolatilitySpike())
      return false;

   if(!PassesLiquidityFilter())
      return false;

   return true;
}

int EntrySignal()
{
   double fast[3], slow[3], rsi[2], atr[2];
   if(CopyBuffer(g_fastMaHandle, 0, 0, 3, fast) < 3) return 0;
   if(CopyBuffer(g_slowMaHandle, 0, 0, 3, slow) < 3) return 0;
   if(CopyBuffer(g_rsiHandle, 0, 0, 2, rsi) < 2) return 0;
   if(CopyBuffer(g_atrHandle, 0, 0, 2, atr) < 2) return 0;

   bool bullishCross = (fast[1] <= slow[1] && fast[0] > slow[0]);
   bool bearishCross = (fast[1] >= slow[1] && fast[0] < slow[0]);

   bool longOk = InpEnableLongs && bullishCross && rsi[0] >= InpRsiLongThreshold && atr[0] > 0;
   bool shortOk = InpEnableShorts && bearishCross && rsi[0] <= InpRsiShortThreshold && atr[0] > 0;

   if(longOk)  return 1;
   if(shortOk) return -1;
   return 0;
}

void PlaceOrderBySignal(const int signal)
{
   double atrValue = LatestAtr();
   if(atrValue <= 0.0)
      return;

   double slDistance = atrValue * InpAtrSLMultiplier;
   double tpDistance = atrValue * InpAtrTPMultiplier;
   double volume = CalculateVolumeFromRisk(slDistance);
   if(volume <= 0.0)
      return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double price = (signal > 0) ? ask : bid;
   double sl = (signal > 0) ? (price - slDistance) : (price + slDistance);
   double tp = (signal > 0) ? (price + tpDistance) : (price - tpDistance);

   if(!NormalizeStops(signal, price, sl, tp))
      return;

   bool placed = false;
   for(int i = 0; i <= InpMaxRetries; i++)
   {
      if(CurrentSpreadPoints() > InpMaxSpreadPoints)
         break;

      if(signal > 0)
         placed = trade.Buy(volume, _Symbol, 0.0, sl, tp, "xpticks-long");
      else
         placed = trade.Sell(volume, _Symbol, 0.0, sl, tp, "xpticks-short");

      if(placed)
         break;
   }

   if(!placed)
      PrintFormat("Order failed after retries. retcode=%d", trade.ResultRetcode());
}

void ManageOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double volume = PositionGetDouble(POSITION_VOLUME);
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);

      double atr = LatestAtr();
      if(atr <= 0.0)
         continue;

      double riskDistance = atr * InpAtrSLMultiplier;
      double rNow = CurrentR(type, openPrice, riskDistance);

      // Break-even
      if(rNow >= InpBreakEvenR)
      {
         double be = openPrice;
         if(type == POSITION_TYPE_BUY && (sl < be || sl == 0.0))
            trade.PositionModify(ticket, be, tp);
         if(type == POSITION_TYPE_SELL && (sl > be || sl == 0.0))
            trade.PositionModify(ticket, be, tp);
      }

      // Trailing
      if(rNow >= InpTrailStartR)
      {
         double step = InpTrailStepR * riskDistance;
         double newSl = sl;
         if(type == POSITION_TYPE_BUY)
         {
            double ref = SymbolInfoDouble(_Symbol, SYMBOL_BID) - step;
            if(ref > sl)
               newSl = ref;
         }
         else
         {
            double ref = SymbolInfoDouble(_Symbol, SYMBOL_ASK) + step;
            if(sl == 0.0 || ref < sl)
               newSl = ref;
         }

         if(newSl != sl)
            trade.PositionModify(ticket, newSl, tp);
      }

      // Partial close
      if(InpEnablePartialClose && rNow >= InpPartialCloseAtR)
      {
         double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         double stepVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         double closeVol = NormalizeVolume(volume * InpPartialClosePct, stepVol, minVol);
         if(closeVol >= minVol && (volume - closeVol) >= minVol)
            trade.PositionClosePartial(ticket, closeVol);
      }

      // Time-based exit
      int barsOpen = Bars(_Symbol, _Period, openTime, TimeCurrent());
      if(barsOpen >= InpMaxBarsInTrade)
         trade.PositionClose(ticket);
   }
}

bool IsVolatilitySpike()
{
   double atrSeries[100];
   int n = CopyBuffer(g_atrHandle, 0, 1, 100, atrSeries);
   if(n < 20)
      return false;

   ArraySort(atrSeries);
   double median = atrSeries[n / 2];
   double latest = LatestAtr();
   if(median <= 0.0)
      return false;

   return latest > (median * InpMaxAtrMultiplierVsMedian);
}

bool PassesLiquidityFilter()
{
   long tv = (long)iVolume(_Symbol, _Period, 1);
   return tv >= InpMinTickVolume;
}

bool PassesSessionFilter()
{
   MqlDateTime dt;
   TimeToStruct(TimeTradeServer(), dt);

   if(InpSessionStartHour <= InpSessionEndHour)
      return dt.hour >= InpSessionStartHour && dt.hour < InpSessionEndHour;

   return (dt.hour >= InpSessionStartHour || dt.hour < InpSessionEndHour);
}

bool PassesPortfolioExposureFilter(const int signal)
{
   string base = StringSubstr(_Symbol, 0, 3);
   string quote = StringSubstr(_Symbol, 3, 3);

   int sameCurrencyExposure = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      if(StringLen(sym) < 6)
         continue;

      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      string b = StringSubstr(sym, 0, 3);
      string q = StringSubstr(sym, 3, 3);
      if(b == base || b == quote || q == base || q == quote)
         sameCurrencyExposure++;
   }

   return sameCurrencyExposure < InpMaxSameCurrencyExposure;
}

double CalculateVolumeFromRisk(const double slDistance)
{
   if(slDistance <= 0.0)
      return 0.0;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (InpRiskPerTradePct / 100.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double minVol    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepVol   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(tickValue <= 0.0 || tickSize <= 0.0)
      return 0.0;

   double moneyPerLotAtSL = (slDistance / tickSize) * tickValue;
   if(moneyPerLotAtSL <= 0.0)
      return 0.0;

   double rawVol = riskMoney / moneyPerLotAtSL;
   double normVol = NormalizeVolume(rawVol, stepVol, minVol);

   if(normVol < minVol)
      return 0.0;

   if(normVol > maxVol)
      normVol = maxVol;

   return normVol;
}

double NormalizeVolume(const double volume, const double step, const double min)
{
   if(step <= 0.0)
      return volume;

   double lots = MathFloor(volume / step) * step;
   if(lots < min)
      return 0.0;
   return NormalizeDouble(lots, 2);
}

bool NormalizeStops(const int signal, const double price, double &sl, double &tp)
{
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDistance = stopsLevel * _Point;

   if(signal > 0)
   {
      if((price - sl) < minStopDistance) sl = price - minStopDistance;
      if((tp - price) < minStopDistance) tp = price + minStopDistance;
      if(sl >= price || tp <= price) return false;
   }
   else
   {
      if((sl - price) < minStopDistance) sl = price + minStopDistance;
      if((price - tp) < minStopDistance) tp = price - minStopDistance;
      if(sl <= price || tp >= price) return false;
   }

   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);
   return true;
}

double CurrentR(const long type, const double openPrice, const double riskDistance)
{
   if(riskDistance <= 0.0)
      return 0.0;

   double price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pnlDistance = (type == POSITION_TYPE_BUY) ? (price - openPrice) : (openPrice - price);
   return pnlDistance / riskDistance;
}

double LatestAtr()
{
   double atr[1];
   if(CopyBuffer(g_atrHandle, 0, 0, 1, atr) < 1)
      return 0.0;
   return atr[0];
}

double CurrentSpreadPoints()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return (ask - bid) / _Point;
}

int CountOpenPositionsForSymbol()
{
   int c = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && (long)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         c++;
   }
   return c;
}

void ResetDayWeekBaselines()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   int currentDayOfYear = dt.day_of_year;
   int currentWeekIndex = dt.day_of_year / 7;

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);

   if(g_dayOfYear != currentDayOfYear)
   {
      g_dayOfYear = currentDayOfYear;
      g_dayStartEquity = eq;
   }

   if(g_weekIndex != currentWeekIndex)
   {
      g_weekIndex = currentWeekIndex;
      g_weekStartEquity = eq;
   }

   if(g_dayStartEquity <= 0.0) g_dayStartEquity = eq;
   if(g_weekStartEquity <= 0.0) g_weekStartEquity = eq;
}

double CurrentDayDrawdownPct()
{
   if(g_dayStartEquity <= 0.0)
      return 0.0;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq >= g_dayStartEquity)
      return 0.0;
   return ((g_dayStartEquity - eq) / g_dayStartEquity) * 100.0;
}

double CurrentWeekDrawdownPct()
{
   if(g_weekStartEquity <= 0.0)
      return 0.0;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq >= g_weekStartEquity)
      return 0.0;
   return ((g_weekStartEquity - eq) / g_weekStartEquity) * 100.0;
}
