//+------------------------------------------------------------------+
//| Ichimoku_MTF.mq5                                                 +
//| Ichimoku Cloud Trend Following (Multi-Timeframe)                 +
//| Higher TF for trend confirmation, Lower TF for entry signals      +
//| With trailing stop and cloud filter                               +
//+------------------------------------------------------------------+
#property copyright "2025"
#property link      ""
#property version   "2.00"
#property strict

#include <Trade/Trade.mqh>

// ===== INPUTS =====
input ENUM_TIMEFRAMES HigherTF = PERIOD_D1;           // Higher timeframe for trend confirmation
input ENUM_TIMEFRAMES EntryTF = PERIOD_H4;            // Entry timeframe for signals
input int TenkanPeriod = 9;                            // Tenkan-sen period
input int KijunPeriod = 26;                            // Kijun-sen period
input int SenkouBPeriod = 52;                          // Senkou Span B period

// Money management
input double RiskPercent = 1.0;                        // % of equity to risk per trade
input double MinLot = 0.01;
input double MaxLot = 1.0;

input double SLMultiplier = 1.0;                       // SL distance multiplier (smaller = less loss per trade)
input double TPMultiplier = 3.0;                       // TP = Risk * TPMultiplier
input double TrailingStartPips = 20.0;                // Profit threshold to start trailing
input double TrailingStopPips = 10.0;                 // Trailing stop distance
input int Slippage = 3;
input ulong MagicNumber = 200302;

// Indicator handles
int handleIchimokuHigh = INVALID_HANDLE;              // Higher TF
int handleIchimokuEntry = INVALID_HANDLE;             // Entry TF

CTrade trade;

//+------------------------------------------------------------------+
int OnInit()
	{
	 handleIchimokuHigh = iIchimoku(Symbol(), HigherTF, TenkanPeriod, KijunPeriod, SenkouBPeriod);
	 handleIchimokuEntry = iIchimoku(Symbol(), EntryTF, TenkanPeriod, KijunPeriod, SenkouBPeriod);

	 if(handleIchimokuHigh == INVALID_HANDLE || handleIchimokuEntry == INVALID_HANDLE)
		 {
			Print("Failed to create Ichimoku indicator handles");
			return(INIT_FAILED);
		 }

	 trade.SetExpertMagicNumber(MagicNumber);
	 trade.SetDeviationInPoints(Slippage);

	 Print("Ichimoku MTF EA initialized - Higher TF: ", EnumToString(HigherTF), " Entry TF: ", EnumToString(EntryTF));
	 return(INIT_SUCCEEDED);
	}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
	{
	 if(handleIchimokuHigh != INVALID_HANDLE) IndicatorRelease(handleIchimokuHigh);
	 if(handleIchimokuEntry != INVALID_HANDLE) IndicatorRelease(handleIchimokuEntry);
	 Print("Ichimoku MTF EA deinitialized");
	}

//+------------------------------------------------------------------+
void OnTick()
	{
	 double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
	 double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
	 double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);

	 // ===== HIGHER TIMEFRAME TREND CONFIRMATION =====
	 double tenkanHigh[2], kijunHigh[2], senkouAHigh[2], senkouBHigh[2];
	 
	 if(CopyBuffer(handleIchimokuHigh, 0, 0, 2, tenkanHigh) < 2) return;
	 if(CopyBuffer(handleIchimokuHigh, 1, 0, 2, kijunHigh) < 2) return;
	 if(CopyBuffer(handleIchimokuHigh, 2, 0, 2, senkouAHigh) < 2) return;
	 if(CopyBuffer(handleIchimokuHigh, 3, 0, 2, senkouBHigh) < 2) return;

	 double cloudTopHigh = MathMax(senkouAHigh[0], senkouBHigh[0]);
	 double cloudBotHigh = MathMin(senkouAHigh[0], senkouBHigh[0]);
	 
	 // Trend: Tenkan above Kijun on higher TF = uptrend, below = downtrend
	 int trendHigh = 0;  // 0=flat, 1=up, -1=down
	 
	 if(tenkanHigh[0] > kijunHigh[0])
	 	trendHigh = 1;  // Uptrend
	 else if(tenkanHigh[0] < kijunHigh[0])
	 	trendHigh = -1;  // Downtrend

	 // ===== ENTRY TIMEFRAME SIGNALS =====
	 double tenkanEntry[2], kijunEntry[2], senkouAEntry[2], senkouBEntry[2];
	 
	 if(CopyBuffer(handleIchimokuEntry, 0, 0, 2, tenkanEntry) < 2) return;
	 if(CopyBuffer(handleIchimokuEntry, 1, 0, 2, kijunEntry) < 2) return;
	 if(CopyBuffer(handleIchimokuEntry, 2, 0, 2, senkouAEntry) < 2) return;
	 if(CopyBuffer(handleIchimokuEntry, 3, 0, 2, senkouBEntry) < 2) return;

	 double cloudTopEntry = MathMax(senkouAEntry[0], senkouBEntry[0]);
	 double cloudBotEntry = MathMin(senkouAEntry[0], senkouBEntry[0]);
	 double cloudHeightEntry = MathAbs(cloudTopEntry - cloudBotEntry);
	 
	 double entryClose = iClose(Symbol(), EntryTF, 0);
	 double entryHigh = iHigh(Symbol(), EntryTF, 0);
	 double entryLow = iLow(Symbol(), EntryTF, 0);

	 // Entry signals with multiple filters
	 bool buySignal = false;
	 bool sellSignal = false;

	 // Buy conditions:
	 // 1. Uptrend on higher TF (Tenkan > Kijun)
	 // 2. Either: a) Tenkan > Kijun on entry TF, OR b) Price above cloud on entry TF
	 if(trendHigh == 1)
		 {
			bool tenkanAboveKijun = (tenkanEntry[0] > kijunEntry[0]);
			bool priceAboveCloud = (entryClose > cloudTopEntry);
			if(tenkanAboveKijun || priceAboveCloud)
				buySignal = true;
		 }

	 // Sell conditions:
	 // 1. Downtrend on higher TF (Tenkan < Kijun)
	 // 2. Either: a) Tenkan < Kijun on entry TF, OR b) Price below cloud on entry TF
	 if(trendHigh == -1)
		 {
			bool tenkanBelowKijun = (tenkanEntry[0] < kijunEntry[0]);
			bool priceBelowCloud = (entryClose < cloudBotEntry);
			if(tenkanBelowKijun || priceBelowCloud)
				sellSignal = true;
		 }

	 // Count existing EA positions
	 int currentPositions = 0;
	 for(int i = 0; i < PositionsTotal(); i++)
		 {
			if(PositionGetTicket(i) <= 0) continue;
			if(PositionSelectByTicket(PositionGetTicket(i)))
				{
				 if(PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber && PositionGetString(POSITION_SYMBOL) == Symbol())
					 currentPositions++;
				}
		 }

	 // Update trailing stops
	 UpdateTrailingStops(ask, bid, point);

	 // Entry logic
	 if(currentPositions == 0)
		 {
			double lot = CalculateLotSize(cloudHeightEntry);
			if(lot < MinLot) lot = MinLot;
			if(lot > MaxLot) lot = MaxLot;

			// Debug output only when signals are detected
			if(buySignal || sellSignal)
				{
				 Print("=== ENTRY SIGNAL ===");
				 Print("TrendHigh=", trendHigh, " BuySignal=", buySignal, " SellSignal=", sellSignal);
				 Print("TenkanH=", tenkanHigh[0], " KijunH=", kijunHigh[0], " TenkanE=", tenkanEntry[0], " KijunE=", kijunEntry[0]);
				 Print("CloudTop=", cloudTopEntry, " CloudBot=", cloudBotEntry, " Price=", entryClose);
				}

			if(buySignal)
				{
				 double entryPrice = ask;
				 double sl = cloudBotEntry - cloudHeightEntry * SLMultiplier;
				 if(sl >= entryPrice) sl = entryPrice - cloudHeightEntry * SLMultiplier;
				 double tp = entryPrice + (entryPrice - sl) * TPMultiplier;
				 
				 if(trade.Buy(lot, Symbol(), entryPrice, sl, tp, "Ichimoku_MTF_Buy"))
					 Print(">>> BUY OPENED: lot=", lot, " Entry=", entryPrice, " SL=", sl, " TP=", tp);
				 else
					 Print(">>> BUY FAILED: ", GetLastError());
				}
			else if(sellSignal)
				{
				 double entryPrice = bid;
				 double sl = cloudTopEntry + cloudHeightEntry * SLMultiplier;
				 if(sl <= entryPrice) sl = entryPrice + cloudHeightEntry * SLMultiplier;
				 double tp = entryPrice - (sl - entryPrice) * TPMultiplier;
				 
				 if(trade.Sell(lot, Symbol(), entryPrice, sl, tp, "Ichimoku_MTF_Sell"))
					 Print(">>> SELL OPENED: lot=", lot, " Entry=", entryPrice, " SL=", sl, " TP=", tp);
				 else
					 Print(">>> SELL FAILED: ", GetLastError());
				}
		 }
	}

//+------------------------------------------------------------------+
double CalculateLotSize(double riskDistance)
	{
	 if(riskDistance <= 0) return(MinLot);
	 
	 double equity = AccountInfoDouble(ACCOUNT_EQUITY);
	 double riskMoney = equity * (RiskPercent / 100.0);

	 double tickValue = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
	 double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
	 
	 if(tickValue <= 0 || tickSize <= 0)
		 {
			double approx = riskMoney / (riskDistance * 100000.0);
			return(NormalizeLot(approx));
		 }
	 
	 double valuePerPoint = tickValue / tickSize;
	 double riskPerLot = valuePerPoint * riskDistance;
	 
	 if(riskPerLot <= 0) return(MinLot);
	 
	 double lots = riskMoney / riskPerLot;
	 return(NormalizeLot(lots));
	}

//+------------------------------------------------------------------+
double NormalizeLot(double lots)
	{
	 double step = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
	 if(step <= 0) step = 0.01;
	 
	 double minV = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
	 if(minV <= 0) minV = MinLot;
	 
	 double maxV = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
	 if(maxV <= 0) maxV = MaxLot;

	 double normalized = MathFloor(lots / step) * step;
	 if(normalized < minV) normalized = minV;
	 if(normalized > maxV) normalized = maxV;
	 
	 return(NormalizeDouble(normalized, 2));
	}

//+------------------------------------------------------------------+
void UpdateTrailingStops(double ask, double bid, double point)
	{
	 for(int i = PositionsTotal() - 1; i >= 0; i--)
		 {
			ulong ticket = PositionGetTicket(i);
			if(ticket <= 0) continue;
			if(!PositionSelectByTicket(ticket)) continue;
			
			if(PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber || PositionGetString(POSITION_SYMBOL) != Symbol())
			   continue;
			
			ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
			double posOpenPrice = PositionGetDouble(POSITION_PRICE_OPEN);
			double posSL = PositionGetDouble(POSITION_SL);
			double posTP = PositionGetDouble(POSITION_TP);
			
			double trailingDistancePips = TrailingStopPips * point;
			double trailingStartPips = TrailingStartPips * point;
			
			if(posType == POSITION_TYPE_BUY)
				{
				 double currentProfit = ask - posOpenPrice;
				 if(currentProfit >= trailingStartPips)
					 {
						double newSL = ask - trailingDistancePips;
						if(newSL > posSL + point)
							{
							   if(!trade.PositionModify(Symbol(), newSL, posTP))
							   {
								  Print("Failed to update BUY trailing SL");
							   }
							}
					 }
				}
			else if(posType == POSITION_TYPE_SELL)
				{
				 double currentProfit = posOpenPrice - bid;
				 if(currentProfit >= trailingStartPips)
					 {
						double newSL = bid + trailingDistancePips;
						if(newSL < posSL - point)
							{
							   if(!trade.PositionModify(Symbol(), newSL, posTP))
							   {
								  Print("Failed to update SELL trailing SL");
							   }
							}
					 }
				}
		 }
	}

//+------------------------------------------------------------------+
