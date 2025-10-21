//+------------------------------------------------------------------+
//| Ichimoku_Stable.mq5                                              +
//| Ichimoku Cloud - Conservative & Stable Strategy                  +
//| Uses Ichimoku ONLY for trend + price action confirmation          +
//| Fewer trades, higher quality signals                              +
//+------------------------------------------------------------------+
#property copyright "2025"
#property link      ""
#property version   "5.00"
#property strict

#include <Trade/Trade.mqh>

// ===== INPUT PARAMETERS =====
input ENUM_TIMEFRAMES ChartTF = PERIOD_H4;            // Use H4 to reduce noise
input int TenkanPeriod = 9;
input int KijunPeriod = 26;
input int SenkouBPeriod = 52;

// ===== MONEY MANAGEMENT =====
input double RiskPercentPerTrade = 0.5;               // 0.5% risk
input double MinLot = 0.01;
input double MaxLot = 0.5;

// ===== STOP LOSS & TAKE PROFIT =====
input double StopLossPoints = 80.0;                   // Wider SL for safety
input double TakeProfitPoints = 120.0;                // 1.5:1 ratio (better than 2:1 with filtering)

// ===== TRAILING STOP =====
input double TrailingTriggerPoints = 40.0;
input double TrailingStopDistancePoints = 20.0;

// ===== FILTERS =====
input int MinBarsBetweeEntries = 5;                  // Min 5 bars between entries
input bool UseCloudFilter = true;                     // Only trade when price aligns with cloud

input int MaxOpenPositions = 1;
input int Slippage = 5;
input ulong MagicNumber = 200305;

// Handles
int handleIchimoku = INVALID_HANDLE;
CTrade trade;
int lastEntryBar = -1;  // Track last entry bar

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
	 
	 Print("[INFO] Ichimoku Stable v5 Initialized");
	 Print("[INFO] TF=", EnumToString(ChartTF), " Risk=", RiskPercentPerTrade, "%");
	 Print("[INFO] SL=", StopLossPoints, "pts TP=", TakeProfitPoints, "pts Filter=", UseCloudFilter);
	 
	 return(INIT_SUCCEEDED);
	}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
	{
	 if(handleIchimoku != INVALID_HANDLE) 
		 IndicatorRelease(handleIchimoku);
	 Print("[INFO] Ichimoku Stable v5 Deinitialized");
	}

//+------------------------------------------------------------------+
void OnTick()
	{
	 // Get price info
	 double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
	 double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
	 double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
	 int currentBar = (int)iBars(Symbol(), ChartTF);

	 // Get Ichimoku values
	 double tenkan[3], kijun[3], senkouA[3], senkouB[3];
	 
	 if(CopyBuffer(handleIchimoku, 0, 0, 3, tenkan) < 3) return;
	 if(CopyBuffer(handleIchimoku, 1, 0, 3, kijun) < 3) return;
	 if(CopyBuffer(handleIchimoku, 2, 0, 3, senkouA) < 3) return;
	 if(CopyBuffer(handleIchimoku, 3, 0, 3, senkouB) < 3) return;

	 double cloudTop0 = MathMax(senkouA[0], senkouB[0]);
	 double cloudBot0 = MathMin(senkouA[0], senkouB[0]);
	 double cloudTop1 = MathMax(senkouA[1], senkouB[1]);
	 double cloudBot1 = MathMin(senkouA[1], senkouB[1]);
	 
	 double close0 = iClose(Symbol(), ChartTF, 0);
	 double close1 = iClose(Symbol(), ChartTF, 1);

	 // ===== ENTRY LOGIC WITH FILTERS =====
	 // Buy signal: Tenkan crosses above Kijun AND (price is above cloud OR price breaks above cloud)
	 bool buySignal = false;
	 if((tenkan[1] <= kijun[1]) && (tenkan[0] > kijun[0]))
		 {
			// Filter 1: Cloud alignment
			if(UseCloudFilter)
				{
				 if((close0 > cloudTop0) || (close1 <= cloudBot1 && close0 > cloudBot0))
					 buySignal = true;
				}
			else
				buySignal = true;
		 }

	 // Sell signal: Tenkan crosses below Kijun AND (price is below cloud OR price breaks below cloud)
	 bool sellSignal = false;
	 if((tenkan[1] >= kijun[1]) && (tenkan[0] < kijun[0]))
		 {
			// Filter 1: Cloud alignment
			if(UseCloudFilter)
				{
				 if((close0 < cloudBot0) || (close1 >= cloudTop1 && close0 < cloudTop0))
					 sellSignal = true;
				}
			else
				sellSignal = true;
		 }

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

	 // Entry only if no positions AND enough bars have passed
	 if(posCount == 0 && (currentBar - lastEntryBar) > MinBarsBetweeEntries)
		 {
			double lot = CalculateLotSize();
			if(lot < MinLot) lot = MinLot;
			if(lot > MaxLot) lot = MaxLot;

			if(buySignal)
				{
				 double entryPrice = ask;
				 double sl = entryPrice - StopLossPoints * point;
				 double tp = entryPrice + TakeProfitPoints * point;
				 
				 Print("[BUY SIGNAL] T=", DoubleToString(tenkan[0], 5), " K=", DoubleToString(kijun[0], 5), 
				       " Cloud=[", DoubleToString(cloudBot0, 5), ",", DoubleToString(cloudTop0, 5), "]");
				 
				 if(trade.Buy(lot, Symbol(), entryPrice, sl, tp, "[Ichimoku_Stable] Buy"))
					 {
						Print("[BUY OPENED] Lot=", lot, " Entry=", entryPrice, " SL=", sl, " TP=", tp);
						lastEntryBar = currentBar;
					 }
				 else
					 Print("[BUY FAILED] Error:", GetLastError());
				}
			else if(sellSignal)
				{
				 double entryPrice = bid;
				 double sl = entryPrice + StopLossPoints * point;
				 double tp = entryPrice - TakeProfitPoints * point;
				 
				 Print("[SELL SIGNAL] T=", DoubleToString(tenkan[0], 5), " K=", DoubleToString(kijun[0], 5), 
				       " Cloud=[", DoubleToString(cloudBot0, 5), ",", DoubleToString(cloudTop0, 5), "]");
				 
				 if(trade.Sell(lot, Symbol(), entryPrice, sl, tp, "[Ichimoku_Stable] Sell"))
					 {
						Print("[SELL OPENED] Lot=", lot, " Entry=", entryPrice, " SL=", sl, " TP=", tp);
						lastEntryBar = currentBar;
					 }
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
