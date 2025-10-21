//+------------------------------------------------------------------+
//| Ichimoku.mq5                                                     +
//| Ichimoku Cloud Trend Following Expert Advisor                   |
//| Buy when price breaks above cloud, Sell when price breaks below  |
//| With trailing stop                                                +
//+------------------------------------------------------------------+
#property copyright "2025"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

// ===== INPUTS =====
input ENUM_TIMEFRAMES TrendTimeframe = PERIOD_H1;     // Trading timeframe
input int TenkanPeriod = 9;                            // Tenkan-sen period
input int KijunPeriod = 26;                            // Kijun-sen period
input int SenkouBPeriod = 52;                          // Senkou Span B period
input int SenkouAShift = 26;                           // Senkou Span A shift

// Money management
input double RiskPercent = 1.0;                        // % of equity to risk per trade
input double MinLot = 0.01;
input double MaxLot = 1.0;

input double SLMultiplier = 1.5;                       // SL distance multiplier from cloud
input double TPMultiplier = 3.0;                       // TP = Risk * TPMultiplier
input double TrailingStartPips = 20.0;                // Profit threshold to start trailing
input double TrailingStopPips = 10.0;                 // Trailing stop distance

input int Slippage = 3;
input ulong MagicNumber = 200301;

// Indicator handles
int handleIchimoku = INVALID_HANDLE;

CTrade trade;

//+------------------------------------------------------------------+
int OnInit()
	{
	 handleIchimoku = iIchimoku(Symbol(), TrendTimeframe, TenkanPeriod, KijunPeriod, SenkouBPeriod);

	 if(handleIchimoku == INVALID_HANDLE)
		 {
			Print("Failed to create Ichimoku indicator handle");
			return(INIT_FAILED);
		 }

	 trade.SetExpertMagicNumber(MagicNumber);
	 trade.SetDeviationInPoints(Slippage);

	 Print("Ichimoku EA initialized");
	 return(INIT_SUCCEEDED);
	}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
	{
	 if(handleIchimoku != INVALID_HANDLE) IndicatorRelease(handleIchimoku);
	 Print("Ichimoku EA deinitialized");
	}

//+------------------------------------------------------------------+
void OnTick()
	{
	 // Get Ichimoku values: Tenkan, Kijun, SenkouA, SenkouB
	 double tenkan[2], kijun[2], senkouA[2], senkouB[2];
	 
	 // Copy current bar (shift=0) and previous bar (shift=1)
	 if(CopyBuffer(handleIchimoku, 0, 0, 2, tenkan) < 2) return;     // Tenkan-sen
	 if(CopyBuffer(handleIchimoku, 1, 0, 2, kijun) < 2) return;      // Kijun-sen
	 if(CopyBuffer(handleIchimoku, 2, 0, 2, senkouA) < 2) return;    // Senkou Span A
	 if(CopyBuffer(handleIchimoku, 3, 0, 2, senkouB) < 2) return;    // Senkou Span B

	 double tenkan0 = tenkan[0];
	 double tenkan1 = tenkan[1];
	 double kijun0 = kijun[0];
	 double kijun1 = kijun[1];
	 double senkouA0 = senkouA[0];
	 double senkouA1 = senkouA[1];
	 double senkouB0 = senkouB[0];
	 double senkouB1 = senkouB[1];

	 double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
	 double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
	 double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
	 double high0 = iHigh(Symbol(), TrendTimeframe, 0);
	 double low0 = iLow(Symbol(), TrendTimeframe, 0);

	 // Cloud boundaries
	 double cloudTop0 = MathMax(senkouA0, senkouB0);
	 double cloudBottom0 = MathMin(senkouA0, senkouB0);
	 double cloudTop1 = MathMax(senkouA1, senkouB1);
	 double cloudBottom1 = MathMin(senkouA1, senkouB1);

	 // Buy signal: Price crosses above cloud from below
	 // Previous candle was below cloud, current candle breaks above
	 bool buySignal = (low0 < cloudBottom0) && (ask > cloudTop0) && (tenkan0 > kijun0);

	 // Sell signal: Price crosses below cloud from above
	 // Previous candle was above cloud, current candle breaks below
	 bool sellSignal = (high0 > cloudTop0) && (bid < cloudBottom0) && (tenkan0 < kijun0);

	 // Count existing EA positions for this symbol/magic
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

	 // If no open positions, try to open one
	 if(currentPositions == 0)
		 {
			double cloudHeight = MathAbs(cloudTop0 - cloudBottom0);
			if(cloudHeight <= 0) cloudHeight = point * 10;

			double lot = CalculateLotSize(cloudHeight);
			if(lot < MinLot) lot = MinLot;
			if(lot > MaxLot) lot = MaxLot;

			Print("Debug - buySignal=", buySignal, " sellSignal=", sellSignal, 
			      " Tenkan=", tenkan0, " Kijun=", kijun0, " CloudTop=", cloudTop0, " CloudBottom=", cloudBottom0);

			if(buySignal)
				{
				 double price = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
				 double sl = cloudBottom0 - cloudHeight * SLMultiplier;
				 if(sl >= price) sl = price - cloudHeight * SLMultiplier;  // Safety check
				 double tp = price + (price - sl) * TPMultiplier;
				 
				 if(trade.Buy(lot, Symbol(), price, sl, tp, "Ichimoku_Buy"))
					 Print("Buy opened: lot=", lot, " Entry=", price, " SL=", sl, " TP=", tp, " CloudHeight=", cloudHeight);
				 else
					 Print("Buy failed: ", GetLastError());
				}
			else if(sellSignal)
				{
				 double price = SymbolInfoDouble(Symbol(), SYMBOL_BID);
				 double sl = cloudTop0 + cloudHeight * SLMultiplier;
				 if(sl <= price) sl = price + cloudHeight * SLMultiplier;  // Safety check
				 double tp = price - (sl - price) * TPMultiplier;
				 
				 if(trade.Sell(lot, Symbol(), price, sl, tp, "Ichimoku_Sell"))
					 Print("Sell opened: lot=", lot, " Entry=", price, " SL=", sl, " TP=", tp, " CloudHeight=", cloudHeight);
				 else
					 Print("Sell failed: ", GetLastError());
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
