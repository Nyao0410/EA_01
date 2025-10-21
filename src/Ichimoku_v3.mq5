//+------------------------------------------------------------------+
//| Ichimoku_v3.mq5                                                  +
//| Ichimoku Cloud Trend Following (v3 - Aggressive)                 +
//| More frequent entries, tighter stops, quick profit-taking         +
//| Entry TF only (no MTF) to reduce complexity                       +
//+------------------------------------------------------------------+
#property copyright "2025"
#property link      ""
#property version   "3.00"
#property strict

#include <Trade/Trade.mqh>

// ===== INPUTS =====
input ENUM_TIMEFRAMES TradeTF = PERIOD_H1;            // Single timeframe for entry
input int TenkanPeriod = 9;                            // Tenkan-sen period
input int KijunPeriod = 26;                            // Kijun-sen period
input int SenkouBPeriod = 52;                          // Senkou Span B period

// Money management - AGGRESSIVE
input double RiskPercent = 0.5;                        // % of equity to risk per trade (reduced)
input double MinLot = 0.01;
input double MaxLot = 0.5;                            // Reduced max lot

input double SLMultiplier = 0.5;                       // VERY TIGHT SL (aggressive profit taking)
input double TPMultiplier = 2.0;                       // TP = Risk * TPMultiplier
input double TrailingStartPips = 10.0;                // Quick trailing start
input double TrailingStopPips = 5.0;                  // Tight trailing stop

input int MaxOpenPositions = 1;                        // Max 1 position at a time
input int Slippage = 5;
input ulong MagicNumber = 200303;

// Indicator handles
int handleIchimoku = INVALID_HANDLE;

CTrade trade;

//+------------------------------------------------------------------+
int OnInit()
	{
	 handleIchimoku = iIchimoku(Symbol(), TradeTF, TenkanPeriod, KijunPeriod, SenkouBPeriod);

	 if(handleIchimoku == INVALID_HANDLE)
		 {
			Print("Failed to create Ichimoku indicator");
			return(INIT_FAILED);
		 }

	 trade.SetExpertMagicNumber(MagicNumber);
	 trade.SetDeviationInPoints(Slippage);

	 Print("Ichimoku v3 (Aggressive) EA initialized - TF: ", EnumToString(TradeTF));
	 return(INIT_SUCCEEDED);
	}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
	{
	 if(handleIchimoku != INVALID_HANDLE) IndicatorRelease(handleIchimoku);
	 Print("Ichimoku v3 EA deinitialized");
	}

//+------------------------------------------------------------------+
void OnTick()
	{
	 double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
	 double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
	 double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);

	 // Get Ichimoku buffers: current (shift=0) and previous (shift=1)
	 double tenkan[2], kijun[2], senkouA[2], senkouB[2];
	 
	 if(CopyBuffer(handleIchimoku, 0, 0, 2, tenkan) < 2) return;
	 if(CopyBuffer(handleIchimoku, 1, 0, 2, kijun) < 2) return;
	 if(CopyBuffer(handleIchimoku, 2, 0, 2, senkouA) < 2) return;
	 if(CopyBuffer(handleIchimoku, 3, 0, 2, senkouB) < 2) return;

	 double cloudTop = MathMax(senkouA[0], senkouB[0]);
	 double cloudBot = MathMin(senkouA[0], senkouB[0]);
	 double cloudHeight = MathAbs(cloudTop - cloudBot);
	 if(cloudHeight <= 0) cloudHeight = point * 10;

	 double close0 = iClose(Symbol(), TradeTF, 0);
	 double close1 = iClose(Symbol(), TradeTF, 1);

	 // ===== ENTRY SIGNALS (SIMPLE & AGGRESSIVE) =====
	 // Buy: Tenkan crossover above Kijun + Simple trend up
	 bool buySignal = (tenkan[1] <= kijun[1]) && (tenkan[0] > kijun[0]) && (close0 > cloudBot);

	 // Sell: Tenkan crossover below Kijun + Simple trend down
	 bool sellSignal = (tenkan[1] >= kijun[1]) && (tenkan[0] < kijun[0]) && (close0 < cloudTop);

	 // Count existing positions
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

	 // Update trailing stops for existing positions
	 UpdateTrailingStops(ask, bid, point);

	 // Entry only if no open positions
	 if(currentPositions < MaxOpenPositions)
		 {
			double lot = CalculateLotSize(cloudHeight);
			if(lot < MinLot) lot = MinLot;
			if(lot > MaxLot) lot = MaxLot;

			if(buySignal)
				{
				 double entryPrice = ask;
				 double sl = cloudBot - cloudHeight * SLMultiplier;
				 if(sl >= entryPrice) sl = entryPrice - cloudHeight * 0.3;
				 double risk = entryPrice - sl;
				 double tp = entryPrice + (risk * TPMultiplier);
				 
				 Print(">>> BUY SIGNAL: Tenkan=", tenkan[0], " Kijun=", kijun[0], " Cloud=", cloudHeight);
				 
				 if(trade.Buy(lot, Symbol(), entryPrice, sl, tp, "Ichimoku_v3_Buy"))
					 Print(">>> BUY OPENED: lot=", lot, " Entry=", entryPrice, " SL=", sl, " TP=", tp);
				 else
					 Print(">>> BUY FAILED: Error ", GetLastError());
				}
			else if(sellSignal)
				{
				 double entryPrice = bid;
				 double sl = cloudTop + cloudHeight * SLMultiplier;
				 if(sl <= entryPrice) sl = entryPrice + cloudHeight * 0.3;
				 double risk = sl - entryPrice;
				 double tp = entryPrice - (risk * TPMultiplier);
				 
				 Print(">>> SELL SIGNAL: Tenkan=", tenkan[0], " Kijun=", kijun[0], " Cloud=", cloudHeight);
				 
				 if(trade.Sell(lot, Symbol(), entryPrice, sl, tp, "Ichimoku_v3_Sell"))
					 Print(">>> SELL OPENED: lot=", lot, " Entry=", entryPrice, " SL=", sl, " TP=", tp);
				 else
					 Print(">>> SELL FAILED: Error ", GetLastError());
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
		 return(MinLot);
	 
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
								  // Silent fail - don't spam logs
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
								  // Silent fail - don't spam logs
							   }
							}
					 }
				}
		 }
	}

//+------------------------------------------------------------------+
