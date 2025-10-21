//+------------------------------------------------------------------+
//| Ichimoku_Final.mq5                                               +
//| Ichimoku Cloud - Simple & Profitable                             +
//| Strategy: Tenkan/Kijun Crossover + Aggressive Money Management   +
//+------------------------------------------------------------------+
#property copyright "2025"
#property link      ""
#property version   "4.00"
#property strict

#include <Trade/Trade.mqh>

// ===== INPUT PARAMETERS =====
input ENUM_TIMEFRAMES ChartTF = PERIOD_H1;
input int TenkanPeriod = 9;
input int KijunPeriod = 26;
input int SenkouBPeriod = 52;

// ===== MONEY MANAGEMENT - CONSERVATIVE =====
input double RiskPercentPerTrade = 0.3;               // Only 0.3% risk per trade
input double MinLot = 0.01;
input double MaxLot = 0.3;                            // Cap at 0.3 lots

// ===== STOP LOSS & TAKE PROFIT =====
input double StopLossPoints = 50.0;                   // Fixed 50 points SL
input double TakeProfitPoints = 100.0;                // Fixed 100 points TP (2:1 ratio)

// ===== TRAILING STOP =====
input double TrailingTriggerPoints = 50.0;            // Start trailing at 50 pips profit
input double TrailingStopDistancePoints = 20.0;       // Trailing distance 20 points

input int MaxOpenPositions = 1;
input int Slippage = 5;
input ulong MagicNumber = 200304;

// Handles
int handleIchimoku = INVALID_HANDLE;
CTrade trade;

//+------------------------------------------------------------------+
int OnInit()
	{
	 handleIchimoku = iIchimoku(Symbol(), ChartTF, TenkanPeriod, KijunPeriod, SenkouBPeriod);
	 
	 if(handleIchimoku == INVALID_HANDLE)
		 {
			Print("[ERROR] Failed to create Ichimoku indicator");
			return(INIT_FAILED);
		 }
	 
	 trade.SetExpertMagicNumber(MagicNumber);
	 trade.SetDeviationInPoints(Slippage);
	 
	 Print("[INFO] Ichimoku Final v4 Initialized");
	 Print("[INFO] TF=", EnumToString(ChartTF), " Risk=", RiskPercentPerTrade, "% SL=", StopLossPoints, "pts TP=", TakeProfitPoints, "pts");
	 
	 return(INIT_SUCCEEDED);
	}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
	{
	 if(handleIchimoku != INVALID_HANDLE) 
		 IndicatorRelease(handleIchimoku);
	 Print("[INFO] Ichimoku Final v4 Deinitialized");
	}

//+------------------------------------------------------------------+
void OnTick()
	{
	 // Get price info
	 double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
	 double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
	 double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);

	 // Get Ichimoku values
	 double tenkan[2], kijun[2], senkouA[2], senkouB[2];
	 
	 if(CopyBuffer(handleIchimoku, 0, 0, 2, tenkan) < 2) return;
	 if(CopyBuffer(handleIchimoku, 1, 0, 2, kijun) < 2) return;
	 if(CopyBuffer(handleIchimoku, 2, 0, 2, senkouA) < 2) return;
	 if(CopyBuffer(handleIchimoku, 3, 0, 2, senkouB) < 2) return;

	 double cloudTop = MathMax(senkouA[0], senkouB[0]);
	 double cloudBot = MathMin(senkouA[0], senkouB[0]);

	 // ===== ENTRY LOGIC - SIMPLE CROSSOVER =====
	 // Buy: Tenkan crosses above Kijun from below
	 bool buySignal = (tenkan[1] <= kijun[1]) && (tenkan[0] > kijun[0]);
	 
	 // Sell: Tenkan crosses below Kijun from above
	 bool sellSignal = (tenkan[1] >= kijun[1]) && (tenkan[0] < kijun[0]);

	 // Count positions
	 int posCount = 0;
	 for(int i = 0; i < PositionsTotal(); i++)
		 {
			if(PositionGetTicket(i) <= 0) continue;
			if(PositionSelectByTicket(PositionGetTicket(i)))
				{
				 if(PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber && 
				    PositionGetString(POSITION_SYMBOL) == Symbol())
					 posCount++;
				}
		 }

	 // Update trailing stops
	 ManageTrailingStops(ask, bid, point);

	 // Entry only if no positions
	 if(posCount == 0)
		 {
			double lot = CalculateLotSize();
			if(lot < MinLot) lot = MinLot;
			if(lot > MaxLot) lot = MaxLot;

			if(buySignal)
				{
				 double entryPrice = ask;
				 double sl = entryPrice - StopLossPoints * point;
				 double tp = entryPrice + TakeProfitPoints * point;
				 
				 Print("[BUY SIGNAL] Tenkan=", DoubleToString(tenkan[0], 5), 
				       " Kijun=", DoubleToString(kijun[0], 5));
				 
				 if(trade.Buy(lot, Symbol(), entryPrice, sl, tp, "[Ichimoku_Final] Buy"))
					 Print("[BUY OPENED] Lot=", lot, " Entry=", entryPrice, " SL=", sl, " TP=", tp);
				 else
					 Print("[BUY FAILED] Error:", GetLastError());
				}
			else if(sellSignal)
				{
				 double entryPrice = bid;
				 double sl = entryPrice + StopLossPoints * point;
				 double tp = entryPrice - TakeProfitPoints * point;
				 
				 Print("[SELL SIGNAL] Tenkan=", DoubleToString(tenkan[0], 5), 
				       " Kijun=", DoubleToString(kijun[0], 5));
				 
				 if(trade.Sell(lot, Symbol(), entryPrice, sl, tp, "[Ichimoku_Final] Sell"))
					 Print("[SELL OPENED] Lot=", lot, " Entry=", entryPrice, " SL=", sl, " TP=", tp);
				 else
					 Print("[SELL FAILED] Error:", GetLastError());
				}
		 }
	}

//+------------------------------------------------------------------+
double CalculateLotSize()
	{
	 double equity = AccountInfoDouble(ACCOUNT_EQUITY);
	 double riskAmount = equity * (RiskPercentPerTrade / 100.0);
	 
	 double tickValue = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
	 double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
	 
	 if(tickValue <= 0 || tickSize <= 0) 
		 return MinLot;
	 
	 double pointValue = tickValue / tickSize;
	 double riskInPoints = StopLossPoints;
	 double riskPerLot = pointValue * riskInPoints;
	 
	 if(riskPerLot <= 0) return MinLot;
	 
	 double lots = riskAmount / riskPerLot;
	 
	 // Normalize
	 double step = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
	 if(step > 0)
		 lots = MathFloor(lots / step) * step;
	 
	 return NormalizeDouble(lots, 2);
	}

//+------------------------------------------------------------------+
void ManageTrailingStops(double ask, double bid, double point)
	{
	 for(int i = PositionsTotal() - 1; i >= 0; i--)
		 {
			ulong ticket = PositionGetTicket(i);
			if(ticket <= 0) continue;
			
			if(!PositionSelectByTicket(ticket)) continue;
			
			if(PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber ||
			   PositionGetString(POSITION_SYMBOL) != Symbol())
				continue;

			ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
			double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
			double currentSL = PositionGetDouble(POSITION_SL);
			double currentTP = PositionGetDouble(POSITION_TP);
			
			double triggerProfit = TrailingTriggerPoints * point;
			double trailingDist = TrailingStopDistancePoints * point;
			
			if(posType == POSITION_TYPE_BUY)
				{
				 double profit = ask - openPrice;
				 if(profit >= triggerProfit)
					 {
						double newSL = ask - trailingDist;
						if(newSL > currentSL + point)
							trade.PositionModify(Symbol(), newSL, currentTP);
					 }
				}
			else if(posType == POSITION_TYPE_SELL)
				{
				 double profit = openPrice - bid;
				 if(profit >= triggerProfit)
					 {
						double newSL = bid + trailingDist;
						if(newSL < currentSL - point)
							trade.PositionModify(Symbol(), newSL, currentTP);
					 }
				}
		 }
	}

//+------------------------------------------------------------------+
