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

// Professional market structure protection
input int    InpStructureSwingLookbackBars   = 180;
input int    InpStructureSwingStrength       = 3;
input int    InpStructureConfluencePoints    = 120;
input int    InpStructureNearWallPoints      = 260;
input int    InpStructureTrapWidthPoints     = 420;
input int    InpStructureExtremeDanger       = 85;
input int    InpStructureBlockDanger         = 92;
input int    InpStructureMinDirectionScore   = 40;
input double InpImpulseAtrFactor             = 0.22;
input double InpMinCandleBodyRatio           = 0.55;

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
string g_structureZoneStatus = "INIT";
double g_structureDangerLast = 0.0;
int g_structureDirectionLast = 0;

double MarketStructureDangerScore(const int direction, string &zoneStatus);
string MarketStructureClassifyZone(const int direction,
                                   const double nearestResistance,
                                   const double nearestSupport,
                                   const int resistanceConfluence,
                                   const int supportConfluence,
                                   const bool trapped,
                                   const bool displacedAway,
                                   const bool sweepReclaim);
bool MarketStructureProtectionOK(const int direction, string &zoneStatus, double &dangerScore);
bool EntryProtocolOK(const int direction);
double DirectionScore(const int direction, const double structureDanger);
bool ImpulseConfirmsDirection(const int direction);
bool CandleAnatomyStrong(const int direction);
bool DetectDisplacementAwayFromWall(const int direction, const double nearestResistance, const double nearestSupport);
bool DetectSweepReclaim(const int direction, const double nearestResistance, const double nearestSupport);
bool FindNearestStructureWalls(double &nearestResistance, double &nearestSupport, int &resistanceConfluence, int &supportConfluence);
int CollectSwingLevels(const ENUM_TIMEFRAMES timeframe, const int lookback, const int strength, double &prices[], int &types[], int &weights[]);
int TimeframeWeight(const ENUM_TIMEFRAMES timeframe);
void RefreshStructureState();

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
   PrintFormat("[XPTicks Health] disabled=%s dayDD=%.2f%% weekDD=%.2f%% spreadPts=%.1f openPos=%d losses=%d structDir=%d structDanger=%.1f structZone=%s",
               g_autoDisabled ? "true" : "false",
               CurrentDayDrawdownPct(),
               CurrentWeekDrawdownPct(),
               CurrentSpreadPoints(),
               CountOpenPositionsForSymbol(),
               g_consecutiveLosses,
               g_structureDirectionLast,
               g_structureDangerLast,
               g_structureZoneStatus);
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
   RefreshStructureState();

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

   if(longOk)
   {
      if(EntryProtocolOK(1) && DirectionScore(1, g_structureDangerLast) >= InpStructureMinDirectionScore)
         return 1;
   }

   if(shortOk)
   {
      if(EntryProtocolOK(-1) && DirectionScore(-1, g_structureDangerLast) >= InpStructureMinDirectionScore)
         return -1;
   }

   return 0;
}

void RefreshStructureState()
{
   double fast[1], slow[1];
   int direction = 1;
   if(CopyBuffer(g_fastMaHandle, 0, 0, 1, fast) >= 1 && CopyBuffer(g_slowMaHandle, 0, 0, 1, slow) >= 1)
      direction = (fast[0] >= slow[0]) ? 1 : -1;

   string zoneStatus = "";
   double danger = MarketStructureDangerScore(direction, zoneStatus);
   g_structureDirectionLast = direction;
   g_structureDangerLast = danger;
   g_structureZoneStatus = zoneStatus;
}

bool EntryProtocolOK(const int direction)
{
   if(CurrentSpreadPoints() > InpMaxSpreadPoints)
      return false;

   if(!ImpulseConfirmsDirection(direction))
      return false;

   if(!CandleAnatomyStrong(direction))
      return false;

   string zoneStatus = "";
   double dangerScore = 0.0;
   if(!MarketStructureProtectionOK(direction, zoneStatus, dangerScore))
      return false;

   g_structureDirectionLast = direction;
   g_structureDangerLast = dangerScore;
   g_structureZoneStatus = zoneStatus;
   return true;
}

double DirectionScore(const int direction, const double structureDanger)
{
   double score = 100.0;
   score -= structureDanger * 0.65;
   if(ImpulseConfirmsDirection(direction))
      score += 10.0;
   if(CandleAnatomyStrong(direction))
      score += 8.0;
   if(CurrentSpreadPoints() <= (InpMaxSpreadPoints * 0.75))
      score += 6.0;

   if(score < 0.0) score = 0.0;
   if(score > 100.0) score = 100.0;
   return score;
}

bool MarketStructureProtectionOK(const int direction, string &zoneStatus, double &dangerScore)
{
   dangerScore = MarketStructureDangerScore(direction, zoneStatus);
   if(dangerScore >= InpStructureBlockDanger)
      return false;

   double nearestResistance = 0.0;
   double nearestSupport = 0.0;
   int resistanceConfluence = 0;
   int supportConfluence = 0;
   if(!FindNearestStructureWalls(nearestResistance, nearestSupport, resistanceConfluence, supportConfluence))
      return true;

   double price = (direction > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double distToHtfWall = 1.0e10;
   if(direction > 0 && nearestResistance > 0.0)
      distToHtfWall = (nearestResistance - price) / _Point;
   if(direction < 0 && nearestSupport > 0.0)
      distToHtfWall = (price - nearestSupport) / _Point;

   if(distToHtfWall >= 0.0 && distToHtfWall <= InpStructureNearWallPoints && dangerScore >= InpStructureExtremeDanger)
      return false;

   return true;
}

double MarketStructureDangerScore(const int direction, string &zoneStatus)
{
   zoneStatus = "NEUTRAL";
   double nearestResistance = 0.0;
   double nearestSupport = 0.0;
   int resistanceConfluence = 0;
   int supportConfluence = 0;
   if(!FindNearestStructureWalls(nearestResistance, nearestSupport, resistanceConfluence, supportConfluence))
      return 0.0;

   double price = (direction > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double distToResistance = (nearestResistance > 0.0) ? ((nearestResistance - price) / _Point) : 1.0e10;
   double distToSupport = (nearestSupport > 0.0) ? ((price - nearestSupport) / _Point) : 1.0e10;

   bool trapped = (distToResistance >= 0.0 && distToSupport >= 0.0 &&
                   (distToResistance + distToSupport) <= InpStructureTrapWidthPoints);

   bool displacedAway = DetectDisplacementAwayFromWall(direction, nearestResistance, nearestSupport);
   bool sweepReclaim = DetectSweepReclaim(direction, nearestResistance, nearestSupport);
   zoneStatus = MarketStructureClassifyZone(direction,
                                            nearestResistance,
                                            nearestSupport,
                                            resistanceConfluence,
                                            supportConfluence,
                                            trapped,
                                            displacedAway,
                                            sweepReclaim);

   double danger = 10.0;

   if(direction > 0 && distToResistance >= 0.0)
   {
      if(distToResistance <= InpStructureNearWallPoints)
         danger += 35.0;
      else if(distToResistance <= (InpStructureNearWallPoints * 2))
         danger += 20.0;
      if(resistanceConfluence >= 8) danger += 22.0;
      else if(resistanceConfluence >= 5) danger += 12.0;
   }

   if(direction < 0 && distToSupport >= 0.0)
   {
      if(distToSupport <= InpStructureNearWallPoints)
         danger += 35.0;
      else if(distToSupport <= (InpStructureNearWallPoints * 2))
         danger += 20.0;
      if(supportConfluence >= 8) danger += 22.0;
      else if(supportConfluence >= 5) danger += 12.0;
   }

   if(trapped)
      danger += 24.0;

   if(displacedAway)
      danger -= 16.0;

   if(sweepReclaim)
      danger -= 28.0;

   if(danger < 0.0) danger = 0.0;
   if(danger > 100.0) danger = 100.0;
   return danger;
}

string MarketStructureClassifyZone(const int direction,
                                   const double nearestResistance,
                                   const double nearestSupport,
                                   const int resistanceConfluence,
                                   const int supportConfluence,
                                   const bool trapped,
                                   const bool displacedAway,
                                   const bool sweepReclaim)
{
   double price = (direction > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double distToResistance = (nearestResistance > 0.0) ? ((nearestResistance - price) / _Point) : 1.0e10;
   double distToSupport = (nearestSupport > 0.0) ? ((price - nearestSupport) / _Point) : 1.0e10;

   if(sweepReclaim)
      return "BREAKOUT_CONTINUATION_ZONE";
   if(trapped)
      return "LIQUIDITY_POOL";

   if(direction > 0)
   {
      if(distToResistance >= 0.0 && distToResistance <= InpStructureNearWallPoints)
         return (resistanceConfluence >= 8) ? "MAJOR_RESISTANCE" : "MINOR_RESISTANCE";
      if(distToSupport >= 0.0 && distToSupport <= InpStructureNearWallPoints && displacedAway)
         return "BREAKOUT_CONTINUATION_ZONE";
      return "STRUCTURE_OPEN_BUY";
   }

   if(distToSupport >= 0.0 && distToSupport <= InpStructureNearWallPoints)
      return (supportConfluence >= 8) ? "MAJOR_SUPPORT" : "MINOR_SUPPORT";
   if(distToResistance >= 0.0 && distToResistance <= InpStructureNearWallPoints && displacedAway)
      return "BREAKOUT_CONTINUATION_ZONE";
   return "STRUCTURE_OPEN_SELL";
}

bool FindNearestStructureWalls(double &nearestResistance, double &nearestSupport, int &resistanceConfluence, int &supportConfluence)
{
   nearestResistance = 0.0;
   nearestSupport = 0.0;
   resistanceConfluence = 0;
   supportConfluence = 0;

   double levels[];
   int types[];
   int weights[];
   ArrayResize(levels, 0);
   ArrayResize(types, 0);
   ArrayResize(weights, 0);

   ENUM_TIMEFRAMES tfs[5] = {PERIOD_D1, PERIOD_H4, PERIOD_H1, PERIOD_M15, PERIOD_M5};
   int total = 0;
   for(int i = 0; i < 5; i++)
      total += CollectSwingLevels(tfs[i], InpStructureSwingLookbackBars, InpStructureSwingStrength, levels, types, weights);

   if(total <= 0)
      return false;

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double closestResDist = 1.0e10;
   double closestSupDist = 1.0e10;

   for(int i = 0; i < total; i++)
   {
      if(types[i] > 0 && levels[i] >= price)
      {
         double d = levels[i] - price;
         if(d < closestResDist)
         {
            closestResDist = d;
            nearestResistance = levels[i];
         }
      }
      if(types[i] < 0 && levels[i] <= price)
      {
         double d = price - levels[i];
         if(d < closestSupDist)
         {
            closestSupDist = d;
            nearestSupport = levels[i];
         }
      }
   }

   double tol = InpStructureConfluencePoints * _Point;
   for(int i = 0; i < total; i++)
   {
      if(nearestResistance > 0.0 && types[i] > 0 && MathAbs(levels[i] - nearestResistance) <= tol)
         resistanceConfluence += weights[i];
      if(nearestSupport > 0.0 && types[i] < 0 && MathAbs(levels[i] - nearestSupport) <= tol)
         supportConfluence += weights[i];
   }

   return nearestResistance > 0.0 || nearestSupport > 0.0;
}

int CollectSwingLevels(const ENUM_TIMEFRAMES timeframe, const int lookback, const int strength, double &prices[], int &types[], int &weights[])
{
   int bars = Bars(_Symbol, timeframe);
   if(bars <= (strength * 2 + 2))
      return 0;

   int maxLookback = MathMin(lookback, bars - strength - 2);
   int start = strength + 1;
   int collected = 0;
   int tfWeight = TimeframeWeight(timeframe);

   for(int shift = start; shift <= maxLookback; shift++)
   {
      double high = iHigh(_Symbol, timeframe, shift);
      double low  = iLow(_Symbol, timeframe, shift);
      if(high <= 0.0 || low <= 0.0)
         continue;

      bool swingHigh = true;
      bool swingLow = true;
      for(int k = 1; k <= strength; k++)
      {
         if(high <= iHigh(_Symbol, timeframe, shift - k) || high < iHigh(_Symbol, timeframe, shift + k))
            swingHigh = false;
         if(low >= iLow(_Symbol, timeframe, shift - k) || low > iLow(_Symbol, timeframe, shift + k))
            swingLow = false;
         if(!swingHigh && !swingLow)
            break;
      }

      if(swingHigh)
      {
         int idxH = ArraySize(prices);
         ArrayResize(prices, idxH + 1);
         ArrayResize(types, idxH + 1);
         ArrayResize(weights, idxH + 1);
         prices[idxH] = high;
         types[idxH] = 1;
         weights[idxH] = tfWeight;
         collected++;
      }

      if(swingLow)
      {
         int idxL = ArraySize(prices);
         ArrayResize(prices, idxL + 1);
         ArrayResize(types, idxL + 1);
         ArrayResize(weights, idxL + 1);
         prices[idxL] = low;
         types[idxL] = -1;
         weights[idxL] = tfWeight;
         collected++;
      }
   }

   return collected;
}

int TimeframeWeight(const ENUM_TIMEFRAMES timeframe)
{
   if(timeframe == PERIOD_D1) return 5;
   if(timeframe == PERIOD_H4) return 4;
   if(timeframe == PERIOD_H1) return 3;
   if(timeframe == PERIOD_M15) return 2;
   return 1;
}

bool DetectDisplacementAwayFromWall(const int direction, const double nearestResistance, const double nearestSupport)
{
   double atr = LatestAtr();
   if(atr <= 0.0)
      return false;

   double h1Close1 = iClose(_Symbol, PERIOD_H1, 1);
   double h1Open1  = iOpen(_Symbol, PERIOD_H1, 1);
   double m15Close1 = iClose(_Symbol, PERIOD_M15, 1);
   double m15Open1  = iOpen(_Symbol, PERIOD_M15, 1);
   if(h1Close1 <= 0.0 || h1Open1 <= 0.0 || m15Close1 <= 0.0 || m15Open1 <= 0.0)
      return false;

   double impulse = MathAbs(h1Close1 - h1Open1) + MathAbs(m15Close1 - m15Open1);
   bool strongImpulse = impulse >= (atr * 0.9);

   if(direction > 0 && nearestResistance > 0.0)
      return strongImpulse && iClose(_Symbol, PERIOD_M15, 1) < nearestResistance && iClose(_Symbol, PERIOD_M15, 0) > iClose(_Symbol, PERIOD_M15, 1);

   if(direction < 0 && nearestSupport > 0.0)
      return strongImpulse && iClose(_Symbol, PERIOD_M15, 1) > nearestSupport && iClose(_Symbol, PERIOD_M15, 0) < iClose(_Symbol, PERIOD_M15, 1);

   return false;
}

bool DetectSweepReclaim(const int direction, const double nearestResistance, const double nearestSupport)
{
   if(direction > 0 && nearestSupport > 0.0)
   {
      double m5Low1 = iLow(_Symbol, PERIOD_M5, 1);
      double m5Close1 = iClose(_Symbol, PERIOD_M5, 1);
      double m1Close0 = iClose(_Symbol, PERIOD_M1, 0);
      if(m5Low1 < nearestSupport && m5Close1 > nearestSupport && m1Close0 > m5Close1)
         return true;
   }

   if(direction < 0 && nearestResistance > 0.0)
   {
      double m5High1 = iHigh(_Symbol, PERIOD_M5, 1);
      double m5Close1 = iClose(_Symbol, PERIOD_M5, 1);
      double m1Close0 = iClose(_Symbol, PERIOD_M1, 0);
      if(m5High1 > nearestResistance && m5Close1 < nearestResistance && m1Close0 < m5Close1)
         return true;
   }

   return false;
}

bool ImpulseConfirmsDirection(const int direction)
{
   double atr = LatestAtr();
   if(atr <= 0.0)
      return false;

   double close1 = iClose(_Symbol, _Period, 1);
   double open1 = iOpen(_Symbol, _Period, 1);
   if(close1 <= 0.0 || open1 <= 0.0)
      return false;

   double body = close1 - open1;
   if(direction > 0)
      return body > (atr * InpImpulseAtrFactor);
   return body < -(atr * InpImpulseAtrFactor);
}

bool CandleAnatomyStrong(const int direction)
{
   double high = iHigh(_Symbol, _Period, 1);
   double low = iLow(_Symbol, _Period, 1);
   double close = iClose(_Symbol, _Period, 1);
   double open = iOpen(_Symbol, _Period, 1);

   double range = high - low;
   if(range <= 0.0)
      return false;

   double body = MathAbs(close - open);
   double bodyRatio = body / range;
   if(bodyRatio < InpMinCandleBodyRatio)
      return false;

   if(direction > 0)
      return close > open;
   return close < open;
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
