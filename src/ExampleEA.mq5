//+------------------------------------------------------------------+
//| ExampleEA.mq5                                                   |
//| Trend-following EA with Ichimoku (long term) + MACD (short)    |
//| MTF analysis + Event Calendar integration                       |
//| MQ5 Version                                                      |
//+------------------------------------------------------------------+
#property copyright "2025"
#property link      ""
#property version   "2.00"
#property strict

#include <Trade/Trade.mqh>

// ===== LONG TERM (TREND) - Ichimoku on Daily/Weekly =====
input ENUM_TIMEFRAMES LongTermTimeframe = PERIOD_D1;   // Daily for long-term trend
input int TenkanPeriod = 9;                             // Ichimoku Tenkan period
input int KijunPeriod = 26;                             // Ichimoku Kijun period
input int SenkouSpanBPeriod = 52;                       // Ichimoku Senkou Span B period
input int ChikouShift = 26;                             // Ichimoku Chikou shift

// ===== SHORT TERM (ENTRY) - MACD on 1H/4H =====
input ENUM_TIMEFRAMES ShortTermTimeframe = PERIOD_H1;  // 1H for short-term entry
input int MACDFastPeriod = 12;
input int MACDSlowPeriod = 26;
input int MACDSignalPeriod = 9;

// ===== MONEY MANAGEMENT =====
input double RiskPercent = 1.0;                        // % of account per trade
input double MaxLot = 1.0;
input double MinLot = 0.01;
input int ATRPeriod = 14;
input double SLMultiplier = 1.0;                       // SL distance multiplier (ATR * SLMultiplier)
input double TPMultiplier = 2.0;                       // TP distance multiplier (ATR * TPMultiplier)
input double TrailingStopATRMultiplier = 0.5;          // Trailing stop distance

// ===== TRADE SETTINGS =====
input int Slippage = 3;
input ulong MagicNumber = 123456;
input color BuyColor = clrBlue;
input color SellColor = clrRed;
input bool EnableTrailingStop = true;                  // Enable trailing stop adjustment

// ===== EVENT CALENDAR =====
input bool EnableEventFilter = true;                   // Enable/disable event filtering
input int EventMarginMinutes = 60;                     // Minutes before/after high-impact event

// ===== GLOBAL HANDLES =====
int handleIchimoku = INVALID_HANDLE;
int handleMACD = INVALID_HANDLE;
int handleATR = INVALID_HANDLE;

CTrade trade;

int OnInit()
{
   // Initialize indicator handles
   handleIchimoku = iIchimoku(Symbol(), LongTermTimeframe, TenkanPeriod, KijunPeriod, SenkouSpanBPeriod);
   handleMACD = iMACD(Symbol(), ShortTermTimeframe, MACDFastPeriod, MACDSlowPeriod, MACDSignalPeriod, PRICE_CLOSE);
   handleATR = iATR(Symbol(), ShortTermTimeframe, ATRPeriod);

   if (handleIchimoku == INVALID_HANDLE || handleMACD == INVALID_HANDLE || handleATR == INVALID_HANDLE)
   {
      Print("Error creating indicator handles");
      return(INIT_FAILED);
   }

   // Set trade parameters
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);

   Print("ExampleEA initialized (MQ5 version)");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   // Release indicator handles
   if (handleIchimoku != INVALID_HANDLE) IndicatorRelease(handleIchimoku);
   if (handleMACD != INVALID_HANDLE) IndicatorRelease(handleMACD);
   if (handleATR != INVALID_HANDLE) IndicatorRelease(handleATR);

   Print("ExampleEA deinitialized");
}

void OnTick()
{
   // ===== EVENT FILTER CHECK =====
   if (EnableEventFilter && IsNearImportantEvent())
   {
      Print("Near important event - trading suspended");
      return;
   }

   // ===== LONG TERM TREND ANALYSIS (Ichimoku) =====
   double tenkan = 0, kijun = 0, senkouSpanA = 0, senkouSpanB = 0;
   
   if (!GetIchimokuValues(tenkan, kijun, senkouSpanA, senkouSpanB))
   {
      Print("Failed to get Ichimoku values");
      return;
   }

   // Determine long-term trend direction
   int trendDirection = 0;  // 0=no trend, 1=uptrend, -1=downtrend
   
   double close = iClose(Symbol(), LongTermTimeframe, 0);
   
   // Improved trend detection: use Tenkan-Kijun cross + Cloud confirmation
   bool priceAboveTenkan = close > tenkan;
   bool priceAboveKijun = close > kijun;
   bool cloudBullish = senkouSpanA > senkouSpanB;
   bool cloudBearish = senkouSpanA < senkouSpanB;
   
   if (priceAboveTenkan && priceAboveKijun && cloudBullish)
      trendDirection = 1;  // Strong uptrend
   else if (close < tenkan && close < kijun && cloudBearish)
      trendDirection = -1;  // Strong downtrend
   else
      trendDirection = 0;   // No clear trend

   // ===== SHORT TERM ENTRY SIGNAL (MACD) =====
   double macdMain = 0, macdSignal = 0, prevMacdMain = 0, prevMacdSignal = 0;
   
   if (!GetMACDValues(macdMain, macdSignal, prevMacdMain, prevMacdSignal))
   {
      Print("Failed to get MACD values");
      return;
   }

   // MACD cross signals: stricter filtering to avoid false signals
   bool macdBuySignal = (prevMacdMain <= prevMacdSignal) && (macdMain > macdSignal) && (macdMain > 0);
   bool macdSellSignal = (prevMacdMain >= prevMacdSignal) && (macdMain < macdSignal) && (macdMain < 0);

   // ===== COMBINED MTF SIGNAL =====
   bool buySignal = (trendDirection == 1) && macdBuySignal;
   bool sellSignal = (trendDirection == -1) && macdSellSignal;

   // ===== CHECK EXISTING POSITIONS =====
   int total = CountPositions();

   // ===== UPDATE TRAILING STOP FOR EXISTING POSITIONS =====
   if (EnableTrailingStop && total > 0)
   {
      double atr = 0;
      if (GetATRValue(atr))
      {
         UpdateTrailingStop(atr, trendDirection);
      }
   }

   // ===== EXECUTE TRADES =====
   if (total == 0)
   {
      double atr = 0;
      if (!GetATRValue(atr))
      {
         Print("Failed to get ATR value");
         return;
      }

      double lot = CalculateLotSize(atr);
      if (lot < MinLot) lot = MinLot;
      if (lot > MaxLot) lot = MaxLot;

      if (buySignal)
      {
         double price = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
         double sl = price - atr * SLMultiplier;
         double tp = price + atr * TPMultiplier;
         
         if (!trade.Buy(lot, Symbol(), price, sl, tp, "TrendFollowEA"))
         {
            Print("Buy order failed: ", GetLastError());
         }
         else
         {
            Print("Buy opened, ticket=", trade.ResultOrder(), " SL=", sl, " TP=", tp);
         }
      }
      else if (sellSignal)
      {
         double price = SymbolInfoDouble(Symbol(), SYMBOL_BID);
         double sl = price + atr * SLMultiplier;
         double tp = price - atr * TPMultiplier;
         
         if (!trade.Sell(lot, Symbol(), price, sl, tp, "TrendFollowEA"))
         {
            Print("Sell order failed: ", GetLastError());
         }
         else
         {
            Print("Sell opened, ticket=", trade.ResultOrder(), " SL=", sl, " TP=", tp);
         }
      }
   }
}

// ===== INDICATOR VALUE RETRIEVAL =====
bool GetIchimokuValues(double &tenkan, double &kijun, double &senkouSpanA, double &senkouSpanB)
{
   double ichimokuBuffer[5];
   
   if (CopyBuffer(handleIchimoku, 0, 0, 1, ichimokuBuffer) < 1)
      return false;
   tenkan = ichimokuBuffer[0];
   
   if (CopyBuffer(handleIchimoku, 1, 0, 1, ichimokuBuffer) < 1)
      return false;
   kijun = ichimokuBuffer[0];
   
   if (CopyBuffer(handleIchimoku, 2, 0, 1, ichimokuBuffer) < 1)
      return false;
   senkouSpanA = ichimokuBuffer[0];
   
   if (CopyBuffer(handleIchimoku, 3, 0, 1, ichimokuBuffer) < 1)
      return false;
   senkouSpanB = ichimokuBuffer[0];
   
   return true;
}

bool GetMACDValues(double &macdMain, double &macdSignal, double &prevMacdMain, double &prevMacdSignal)
{
   double macdBuffer[2];
   
   if (CopyBuffer(handleMACD, 0, 0, 2, macdBuffer) < 2)
      return false;
   macdMain = macdBuffer[1];
   prevMacdMain = macdBuffer[0];
   
   if (CopyBuffer(handleMACD, 1, 0, 2, macdBuffer) < 2)
      return false;
   macdSignal = macdBuffer[1];
   prevMacdSignal = macdBuffer[0];
   
   return true;
}

bool GetATRValue(double &atr)
{
   double atrBuffer[1];
   
   if (CopyBuffer(handleATR, 0, 0, 1, atrBuffer) < 1)
      return false;
   atr = atrBuffer[0];
   
   return true;
}

// ===== POSITION COUNTING =====
int CountPositions()
{
   int count = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (PositionSelectByTicket(ticket))
      {
         if (PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
             PositionGetString(POSITION_SYMBOL) == Symbol())
         {
            count++;
         }
      }
   }
   return count;
}

// ===== TRAILING STOP UPDATE =====
void UpdateTrailingStop(double atr, int trendDirection)
{
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (!PositionSelectByTicket(ticket)) continue;
      
      if (PositionGetInteger(POSITION_MAGIC) != MagicNumber ||
          PositionGetString(POSITION_SYMBOL) != Symbol())
         continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double posOpenPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double posSL = PositionGetDouble(POSITION_SL);
      double posTP = PositionGetDouble(POSITION_TP);
      double posVolume = PositionGetDouble(POSITION_VOLUME);

      double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
      double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
      double trailingDistance = atr * TrailingStopATRMultiplier;

      // Buy position: move SL and TP upward if price is rising and trend continues
      if (posType == POSITION_TYPE_BUY && trendDirection == 1)
      {
         double newSL = bid - trailingDistance;
         double newTP = bid + atr * TPMultiplier;

         // Only update if new SL is higher than current SL (trailing upward)
         if (newSL > posSL)
         {
            // PositionModify expects symbol in CTrade; use current symbol
            if (!trade.PositionModify(Symbol(), newSL, newTP))
            {
               Print("Failed to modify BUY position: ", GetLastError());
            }
            else
            {
               Print("BUY position modified: SL=", newSL, " TP=", newTP);
            }
         }
      }
      // Sell position: move SL and TP downward if price is falling and trend continues
      else if (posType == POSITION_TYPE_SELL && trendDirection == -1)
      {
         double newSL = ask + trailingDistance;
         double newTP = ask - atr * TPMultiplier;

         // Only update if new SL is lower than current SL (trailing downward)
         if (newSL < posSL)
         {
            if (!trade.PositionModify(Symbol(), newSL, newTP))
            {
               Print("Failed to modify SELL position: ", GetLastError());
            }
            else
            {
               Print("SELL position modified: SL=", newSL, " TP=", newTP);
            }
         }
      }
   }
}

// ===== EVENT CALENDAR FILTER =====
// Simple implementation: avoid trading during high-impact news hours
bool IsNearImportantEvent()
{
   if (!EnableEventFilter) return false;

   // Get current time
   MqlDateTime timeStruct;
   TimeToStruct(TimeCurrent(), timeStruct);
   
   int hour = timeStruct.hour;
   int minute = timeStruct.min;
   
   // Convert current time to minutes since midnight
   int nowMinutes = hour * 60 + minute;

   // Define target event times in minutes since midnight (server time assumptions)
   int event1 = 8 * 60 + 30;   // 08:30
   int event2 = 13 * 60 + 30;  // 13:30

   if (MathAbs(nowMinutes - event1) <= EventMarginMinutes) return true;
   if (MathAbs(nowMinutes - event2) <= EventMarginMinutes) return true;

   return false;
}

// ===== MONEY MANAGEMENT =====
double CalculateLotSize(double atr)
{
   if (atr <= 0) return MinLot;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (RiskPercent / 100.0);

   // stop distance in price units (use ATR * multiplier used in SL)
   double stopDistance = atr * 1.5;

   // Get point value and digits from symbol info
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   
   double pointValue = point;
   if (digits == 3 || digits == 5) pointValue = point * 10; // 5-digit broker adjustment

   // Get tick value and tick size
   double tickValue = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);

   if (tickValue <= 0 || tickSize <= 0)
   {
      // Fallback: approximate lot by riskMoney / (stopDistance * 100000)
      double approx = riskMoney / (stopDistance * 100000.0);
      return NormalizeLot(approx);
   }

   // value per price move = tickValue / tickSize
   double valuePerPoint = tickValue / tickSize;

   // risk per lot = valuePerPoint * stopDistance
   double riskPerLot = valuePerPoint * stopDistance;
   if (riskPerLot <= 0) return MinLot;

   double lots = riskMoney / riskPerLot;
   return NormalizeLot(lots);
}

// Normalize lot to broker step
double NormalizeLot(double lots)
{
   double step = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   if (step <= 0) step = 0.01;
   
   double minLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   if (minLot <= 0) minLot = MinLot;
   
   double maxLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   if (maxLot <= 0) maxLot = MaxLot;

   double normalized = MathFloor(lots / step) * step;
   if (normalized < minLot) normalized = minLot;
   if (normalized > maxLot) normalized = maxLot;
   
   return NormalizeDouble(normalized, 2);
}
