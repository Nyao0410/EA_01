//+------------------------------------------------------------------+
//| TrendFollowEA.mq4                                               |
//| Trend-following EA with Ichimoku (long term) + MACD (short)    |
//| MTF analysis + Event Calendar integration                       |
//+------------------------------------------------------------------+
#property copyright "2025"
#property link      ""
#property version   "2.00"
#property strict

// ===== LONG TERM (TREND) - Ichimoku on Daily/Weekly =====
input int LongTermTimeframe = PERIOD_D1;          // Daily for long-term trend
input int TenkanPeriod = 9;                       // Ichimoku Tenkan period
input int KijunPeriod = 26;                       // Ichimoku Kijun period
input int SenkouSpanBPeriod = 52;                 // Ichimoku Senkou Span B period
input int ChikouShift = 26;                       // Ichimoku Chikou shift

// ===== SHORT TERM (ENTRY) - MACD on 1H/4H =====
input int ShortTermTimeframe = PERIOD_H1;        // 1H for short-term entry
input int MACDFastPeriod = 12;
input int MACDSlowPeriod = 26;
input int MACDSignalPeriod = 9;

// ===== MONEY MANAGEMENT =====
input double RiskPercent = 1.0;                  // % of account per trade
input double MaxLot = 1.0;
input double MinLot = 0.01;
input int ATRPeriod = 14;

// ===== TRADE SETTINGS =====
input int Slippage = 3;
input int MagicNumber = 123456;
input color BuyColor = clrBlue;
input color SellColor = clrRed;

// ===== EVENT CALENDAR =====
input bool EnableEventFilter = true;             // Enable/disable event filtering
input int EventMarginMinutes = 60;               // Minutes before/after high-impact event

int OnInit()
  {
   // initialization
   Print("ExampleEA initialized");
   return(INIT_SUCCEEDED);
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
   // Get Ichimoku components on long-term timeframe
  // iIchimoku: (symbol, timeframe, tenkan, kijun, senkou, mode, shift)
  double tenkan = iIchimoku(NULL, LongTermTimeframe, TenkanPeriod, KijunPeriod, SenkouSpanBPeriod, MODE_TENKANSEN, 0);  // Current tenkan
  double kijun = iIchimoku(NULL, LongTermTimeframe, TenkanPeriod, KijunPeriod, SenkouSpanBPeriod, MODE_KIJUNSEN, 0);   // Current kijun
  double senkouSpanA = iIchimoku(NULL, LongTermTimeframe, TenkanPeriod, KijunPeriod, SenkouSpanBPeriod, MODE_SENKOUSPANA, 0);
  double senkouSpanB = iIchimoku(NULL, LongTermTimeframe, TenkanPeriod, KijunPeriod, SenkouSpanBPeriod, MODE_SENKOUSPANB, 0);

   // Determine long-term trend direction
   int trendDirection = 0;  // 0=no trend, 1=uptrend, -1=downtrend
   
   double close = iClose(NULL, LongTermTimeframe, 0);
   if (close > tenkan && close > kijun && senkouSpanA > senkouSpanB)
     trendDirection = 1;  // Uptrend
   else if (close < tenkan && close < kijun && senkouSpanA < senkouSpanB)
     trendDirection = -1;  // Downtrend

   // ===== SHORT TERM ENTRY SIGNAL (MACD) =====
   // Get MACD on short-term timeframe
  // iMACD: (symbol, timeframe, fast_ema, slow_ema, signal_sma, applied_price, mode, shift)
  double macdMain = iMACD(NULL, ShortTermTimeframe, MACDFastPeriod, MACDSlowPeriod, MACDSignalPeriod, PRICE_CLOSE, MODE_MAIN, 0);
  double macdSignal = iMACD(NULL, ShortTermTimeframe, MACDFastPeriod, MACDSlowPeriod, MACDSignalPeriod, PRICE_CLOSE, MODE_SIGNAL, 0);
  double prevMacdMain = iMACD(NULL, ShortTermTimeframe, MACDFastPeriod, MACDSlowPeriod, MACDSignalPeriod, PRICE_CLOSE, MODE_MAIN, 1);
  double prevMacdSignal = iMACD(NULL, ShortTermTimeframe, MACDFastPeriod, MACDSlowPeriod, MACDSignalPeriod, PRICE_CLOSE, MODE_SIGNAL, 1);

   // MACD cross signals
   bool macdBuySignal = (prevMacdMain <= prevMacdSignal) && (macdMain > macdSignal) && (macdMain > 0);
   bool macdSellSignal = (prevMacdMain >= prevMacdSignal) && (macdMain < macdSignal) && (macdMain < 0);

   // ===== COMBINED MTF SIGNAL =====
   bool buySignal = (trendDirection == 1) && macdBuySignal;
   bool sellSignal = (trendDirection == -1) && macdSellSignal;

   // ===== CHECK EXISTING POSITIONS =====
   int total = 0;
   for (int i = OrdersTotal()-1; i >= 0; i--)
     {
      if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
         if (OrderMagicNumber() == MagicNumber && OrderSymbol() == Symbol())
            total++;
        }
     }

   // ===== EXECUTE TRADES =====
   if (total == 0)
     {
      double atr = iATR(NULL, ShortTermTimeframe, ATRPeriod, 0);
      double lot = CalculateLotSize(atr);
      if (lot < MinLot) lot = MinLot;
      if (lot > MaxLot) lot = MaxLot;

      if (buySignal)
        {
         double price = Ask;
         double sl = price - atr * 1.5;
         double tp = price + atr * 3.0;
         int ticket = OrderSend(Symbol(), OP_BUY, lot, price, Slippage, sl, tp, "TrendFollowEA", MagicNumber, 0, BuyColor);
         if (ticket < 0) Print("Buy order failed: ", GetLastError()); else Print("Buy opened, ticket=", ticket);
        }
      else if (sellSignal)
        {
         double price = Bid;
         double sl = price + atr * 1.5;
         double tp = price - atr * 3.0;
         int ticket = OrderSend(Symbol(), OP_SELL, lot, price, Slippage, sl, tp, "TrendFollowEA", MagicNumber, 0, SellColor);
         if (ticket < 0) Print("Sell order failed: ", GetLastError()); else Print("Sell opened, ticket=", ticket);
        }
     }
  }

void OnDeinit(const int reason)
  {
   Print("TrendFollowEA deinitialized");
  }

// ===== EVENT CALENDAR FILTER =====
// Simple implementation: avoid trading during high-impact news hours
// For more robust event filtering, integrate with external calendar APIs
bool IsNearImportantEvent()
  {
   if (!EnableEventFilter) return false;

   // Simplified: Check if current time is within EventMarginMinutes of typical high-impact times
   // Common high-impact events: USA non-farm payroll (Fri 13:30 EST), FED decisions (2/year), etc.
   
   // For now, a basic implementation: avoid trading on certain hours if needed
   // You can expand this with actual event calendar data from Forex Factory API
   
   int hour = Hour();
   int minute = Minute();
   
   // Example: Avoid trading 1 hour before and after key US data releases (typically 8:30 and 13:30 EST)
   // Note: This is a simplified check; for production, use actual event data
   
   // Check if within EventMarginMinutes of 8:30 (typically major US data like Non-Farm Payroll)
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
   if (atr <= 0) return(MinLot);

   double equity = AccountEquity();
   double riskMoney = equity * (RiskPercent / 100.0);

   // stop distance in price units (use ATR * multiplier used in SL)
   double stopDistance = atr * 1.5;

   // convert stop distance to points for currency pair
   double pointValue = Point;
   if (Digits == 3 || Digits == 5) pointValue = Point * 10; // 5-digit broker adjustment

   // approximate pip value per lot for forex majors: use MarketInfo
   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize = MarketInfo(Symbol(), MODE_TICKSIZE);

   if (tickValue <= 0 || tickSize <= 0)
     {
      // Fallback: approximate lot by riskMoney / (stopDistance * 100000)
      double approx = riskMoney / (stopDistance * 100000.0);
      return(NormalizeLot(approx));
     }

   // value per price move = tickValue / tickSize
   double valuePerPoint = tickValue / tickSize;

   // risk per lot = valuePerPoint * stopDistance
   double riskPerLot = valuePerPoint * stopDistance;
   if (riskPerLot <= 0) return(MinLot);

   double lots = riskMoney / riskPerLot;
   return(NormalizeLot(lots));
  }

// Normalize lot to broker step
double NormalizeLot(double lots)
  {
   double step = MarketInfo(Symbol(), MODE_LOTSTEP);
   if (step <= 0) step = 0.01;
   double minLot = MarketInfo(Symbol(), MODE_MINLOT);
   if (minLot <= 0) minLot = MinLot;
   double normalized = MathFloor(lots / step) * step;
   if (normalized < minLot) normalized = minLot;
   return(NormalizeDouble(normalized, 2));
  }
