//+------------------------------------------------------------------+
//| ATR01.mq5                                                       +
//| ATR-based Volatility Filtering Expert Advisor                   |
//| Only trade when current ATR > 2x average ATR (strong direction) |
//+------------------------------------------------------------------+
#property copyright "2025"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

// ===== INPUTS =====
input ENUM_TIMEFRAMES LongTermTimeframe = PERIOD_H4;   // Trend timeframe (MACD zero-line)
input ENUM_TIMEFRAMES ShortTermTimeframe = PERIOD_H1;  // Entry timeframe (MACD cross)

input int MACDFast = 12;
input int MACDSlow = 26;
input int MACDSignal = 9;
input int SwingLookback = 10;    // lookback bars for swing high/low

// Money management
input double RiskPercent = 1.0;    // % of equity to risk per trade
input double MinLot = 0.01;
input double MaxLot = 1.0;
input int ATRPeriod = 14;
input int ATRAvgPeriod = 50;       // Period for average ATR calculation

input double SLMultiplier = 1.5;   // SL = ATR * SLMultiplier
input double TPMultiplier = 2.0;   // TP = ATR * TPMultiplier
input double ATRMultiplier = 2.0;  // Only trade when current ATR > avgATR * ATRMultiplier
input double BreakoutBuffer = 10.0;        // Buffer for swing breakout in points
input double TrailingStartPips = 20.0;     // Profit threshold to start trailing
input double TrailingStopPips = 10.0;      // Trailing stop distance

input int Slippage = 3;
input ulong MagicNumber = 200102;

// Indicator handles
int handleMACDLong = INVALID_HANDLE;
int handleMACDShort = INVALID_HANDLE;
int handleATR = INVALID_HANDLE;

CTrade trade;

//+------------------------------------------------------------------+
int OnInit()
	{
	 handleMACDLong  = iMACD(Symbol(), LongTermTimeframe, MACDFast, MACDSlow, MACDSignal, PRICE_CLOSE);
	 handleMACDShort = iMACD(Symbol(), ShortTermTimeframe, MACDFast, MACDSlow, MACDSignal, PRICE_CLOSE);
	 handleATR       = iATR(Symbol(), ShortTermTimeframe, ATRPeriod);

	 if(handleMACDLong==INVALID_HANDLE || handleMACDShort==INVALID_HANDLE || handleATR==INVALID_HANDLE)
		 {
			Print("Failed to create indicator handles");
			return(INIT_FAILED);
		 }

	 trade.SetExpertMagicNumber(MagicNumber);
	 trade.SetDeviationInPoints(Slippage);

	 Print("ATR01 initialized");
	 return(INIT_SUCCEEDED);
	}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
	{
	 if(handleMACDLong!=INVALID_HANDLE) IndicatorRelease(handleMACDLong);
	 if(handleMACDShort!=INVALID_HANDLE) IndicatorRelease(handleMACDShort);
	 if(handleATR!=INVALID_HANDLE) IndicatorRelease(handleATR);
	 Print("ATR01 deinitialized");
	}

//+------------------------------------------------------------------+
void OnTick()
	{
	 // Read long-term MACD main value on CLOSED bars (shift=1 and shift=2) for momentum check
	 double macdLongMain_1[1], macdLongMain_2[1];
	 if(CopyBuffer(handleMACDLong,0,1,1,macdLongMain_1) < 1) return;
	 if(CopyBuffer(handleMACDLong,0,2,1,macdLongMain_2) < 1) return;
	 double longMain = macdLongMain_1[0];
	 double longMainPrev = macdLongMain_2[0];

	 int longTrend = 0; // 1=up, -1=down, 0=flat/unclear
	 if(longMain > 0 && longMainPrev < longMain) 
	 	longTrend = 1;
	 else if(longMain < 0 && longMainPrev > longMain)
	 	longTrend = -1;

	 // Read short-term MACD main and signal on CLOSED bars (shift=1 and shift=2) for confirmed crosses
	 double macdMain_1[1], macdMain_2[1];
	 double macdSig_1[1], macdSig_2[1];
	 double macdMain_0[1], macdSig_0[1];  // Current forming bar for confirmation
	 if(CopyBuffer(handleMACDShort,0,1,1,macdMain_1) < 1) return;
	 if(CopyBuffer(handleMACDShort,0,2,1,macdMain_2) < 1) return;
	 if(CopyBuffer(handleMACDShort,1,1,1,macdSig_1) < 1) return;
	 if(CopyBuffer(handleMACDShort,1,2,1,macdSig_2) < 1) return;
	 if(CopyBuffer(handleMACDShort,0,0,1,macdMain_0) < 1) return;  // Current bar confirmation
	 if(CopyBuffer(handleMACDShort,1,0,1,macdSig_0) < 1) return;

	 double mainCur = macdMain_1[0];
	 double mainPrev = macdMain_2[0];
	 double sigCur  = macdSig_1[0];
	 double sigPrev = macdSig_2[0];
	 double mainNow = macdMain_0[0];   // Current forming bar
	 double sigNow  = macdSig_0[0];

	 bool buyCross  = (mainPrev <= sigPrev) && (mainCur > sigCur) && (mainCur > 0) && (mainNow > sigNow);
	 bool sellCross = (mainPrev >= sigPrev) && (mainCur < sigCur) && (mainCur < 0) && (mainNow < sigNow);

	 // Get recent swing high/low on short-term timeframe
	 double swingHigh = -1.0;
	 double swingLow = -1.0;
	 {
		 double hh = -DBL_MAX;
		 double ll = DBL_MAX;
		 for(int s=1; s<=SwingLookback; s++)
			 {
				double h = iHigh(Symbol(), ShortTermTimeframe, s);
				double l = iLow(Symbol(), ShortTermTimeframe, s);
				if(h > hh) hh = h;
				if(l < ll) ll = l;
			 }
		 swingHigh = hh;
		 swingLow = ll;
	 }

	 double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
	 double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
	 double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
	 
	 // ===== CRITICAL FILTER: ATR-based volatility check =====
	 // Calculate current ATR and average ATR over last 50 bars
	 double atrCurrent = 0.0;
	 double atrAvg = 0.0;
	 {
		 double atrBuf[1];
		 if(CopyBuffer(handleATR,0,0,1,atrBuf) >= 1) atrCurrent = atrBuf[0];
		 
		 // Calculate average ATR over last ATRAvgPeriod bars
		 double atrSum = 0.0;
		 for(int i=0; i<ATRAvgPeriod; i++)
			 {
				if(CopyBuffer(handleATR,0,i,1,atrBuf) < 1) break;
				atrSum += atrBuf[0];
			 }
		 atrAvg = atrSum / ATRAvgPeriod;
	 }
	 
	 // Only trade if current ATR is significantly higher than average (strong direction)
	 if(atrCurrent < atrAvg * ATRMultiplier)
	 {
	 	// Volatility too low - skip trading
	 	return;
	 }
	 
	 double breakoutBuffer = BreakoutBuffer * point;
	 double closeShort = iClose(Symbol(), ShortTermTimeframe, 0);
	 
	 bool buySignal  = (longTrend == 1) && buyCross && (ask > swingHigh + breakoutBuffer) && (closeShort > swingLow);
	 bool sellSignal = (longTrend == -1) && sellCross && (bid < swingLow - breakoutBuffer) && (closeShort < swingHigh);

	 // Count existing EA positions for this symbol/magic
	 int currentPositions = 0;
	 for(int i=0;i<PositionsTotal();i++)
		 {
			if(PositionGetTicket(i) <= 0) continue;
			if(PositionSelectByTicket(PositionGetTicket(i)))
				{
				 if(PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber && PositionGetString(POSITION_SYMBOL) == Symbol())
						currentPositions++;
				}
		 }

	 // Update trailing stop for existing positions
	 UpdateTrailingStops(ask, bid, point, atrCurrent);

	 // If no open positions, try to open one
	 if(currentPositions == 0)
		 {
			double lot = CalculateLotSize(atrCurrent);
			if(lot < MinLot) lot = MinLot;
			if(lot > MaxLot) lot = MaxLot;

				if(buySignal)
				{
				 double price = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
					double sl = swingLow - point*10.0;
					if(!(sl < price)) sl = price - atrCurrent * SLMultiplier;
					double tp = price + atrCurrent * TPMultiplier;
				 if(trade.Buy(lot, Symbol(), price, sl, tp, "ATR_MACD_Buy"))
						Print("Buy opened: lot=",lot," SL=",sl," TP=",tp," Current ATR=",atrCurrent," Avg ATR=",atrAvg);
				 else
						Print("Buy failed: ",GetLastError());
				}
				else if(sellSignal)
				{
				 double price = SymbolInfoDouble(Symbol(), SYMBOL_BID);
					double sl = swingHigh + point*10.0;
					if(!(sl > price)) sl = price + atrCurrent * SLMultiplier;
					double tp = price - atrCurrent * TPMultiplier;
				 if(trade.Sell(lot, Symbol(), price, sl, tp, "ATR_MACD_Sell"))
						Print("Sell opened: lot=",lot," SL=",sl," TP=",tp," Current ATR=",atrCurrent," Avg ATR=",atrAvg);
				 else
						Print("Sell failed: ",GetLastError());
				}
		 }
	}

//+------------------------------------------------------------------+
double CalculateLotSize(double atr)
	{
	 if(atr <= 0) return(MinLot);
	 double equity = AccountInfoDouble(ACCOUNT_EQUITY);
	 double riskMoney = equity * (RiskPercent/100.0);

	 double tickValue = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
	 double tickSize  = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
	 if(tickValue <= 0 || tickSize <= 0)
		 {
			double approx = riskMoney / (atr * 100000.0);
			return(NormalizeLot(approx));
		 }
	 double valuePerPoint = tickValue / tickSize;
	 double stopDistance = atr * SLMultiplier;
	 double riskPerLot = valuePerPoint * stopDistance;
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

	 double normalized = MathFloor(lots/step) * step;
	 if(normalized < minV) normalized = minV;
	 if(normalized > maxV) normalized = maxV;
	 return(NormalizeDouble(normalized,2));
	}

//+------------------------------------------------------------------+
void UpdateTrailingStops(double ask, double bid, double point, double atr)
	{
	 for(int i=PositionsTotal()-1; i>=0; i--)
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
