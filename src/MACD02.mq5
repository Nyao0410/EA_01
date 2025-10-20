//+------------------------------------------------------------------+
//| MACD01.mq5                                                      |
//| Multi-timeframe MACD-only Expert Advisor (MTF MACD)             |
//| Long-term MACD defines trend, short-term MACD cross for entry   |
//+------------------------------------------------------------------+
#property copyright "2025"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

// ===== INPUTS =====
input ENUM_TIMEFRAMES LongTermTimeframe = PERIOD_M15;   // Trend timeframe (MACD zero-line) - changed to M15
input ENUM_TIMEFRAMES ShortTermTimeframe = PERIOD_M5;  // Entry timeframe (MACD cross) - changed to M5

input int MACDFast = 12;
input int MACDSlow = 26;
input int MACDSignal = 9;
input int SwingLookback = 5;     // lookback bars to define swing high/low on short-term timeframe

// Money management
input double RiskPercent = 1.0;    // % of equity to risk per trade
input double MinLot = 0.01;
input double MaxLot = 1.0;
input int ATRPeriod = 14;

input double SLMultiplier = 1.5;   // SL = ATR * SLMultiplier
input double TPMultiplier = 3.0;   // TP = ATR * TPMultiplier

input int Slippage = 3;
input ulong MagicNumber = 200101;
input bool InvertSignals = false;   // if true, buy/sell signals are swapped

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

	 Print("MACD01 initialized");
	 return(INIT_SUCCEEDED);
	}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
	{
	 if(handleMACDLong!=INVALID_HANDLE) IndicatorRelease(handleMACDLong);
	 if(handleMACDShort!=INVALID_HANDLE) IndicatorRelease(handleMACDShort);
	 if(handleATR!=INVALID_HANDLE) IndicatorRelease(handleATR);
	 Print("MACD01 deinitialized");
	}

//+------------------------------------------------------------------+
void OnTick()
	{
	 // Read long-term MACD main value (zero-line trend)
	 double macdLongMain[1];
	 if(CopyBuffer(handleMACDLong,0,0,1,macdLongMain) < 1) return;
	 double longMain = macdLongMain[0];

	 int longTrend = 0; // 1=up, -1=down, 0=flat
	 if(longMain > 0) longTrend = 1; else if(longMain < 0) longTrend = -1;

	 // Read short-term MACD main and signal (current and previous)
	 double macdShortMain[2];
	 double macdShortSignal[2];
	 if(CopyBuffer(handleMACDShort,0,0,2,macdShortMain) < 2) return;
	 if(CopyBuffer(handleMACDShort,1,0,2,macdShortSignal) < 2) return;

	 double mainCur = macdShortMain[1];
	 double mainPrev = macdShortMain[0];
	 double sigCur  = macdShortSignal[1];
	 double sigPrev = macdShortSignal[0];

		 bool buyCross  = (mainPrev <= sigPrev) && (mainCur > sigCur) && (mainCur > 0);
		 bool sellCross = (mainPrev >= sigPrev) && (mainCur < sigCur) && (mainCur < 0);

		 // Get recent swing high/low on short-term timeframe (exclude current forming bar)
		 double swingHigh = -1.0;
		 double swingLow = -1.0;
		 {
			 // compute highest high and lowest low over last SwingLookback bars (shifts 1..SwingLookback)
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

	// Only take entries that align with long-term MACD zero-line
	// Require breakout of recent swing before entering to avoid counter-trend entries
	double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
	double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
	bool buySignalOrig  = (longTrend == 1) && buyCross && (ask > swingHigh);
	bool sellSignalOrig = (longTrend == -1) && sellCross && (bid < swingLow);
	
	// Optionally invert signals (swap buy and sell)
	bool buySignal, sellSignal;
	if(InvertSignals)
	{
		buySignal = sellSignalOrig;
		sellSignal = buySignalOrig;
	}
	else
	{
		buySignal = buySignalOrig;
		sellSignal = sellSignalOrig;
	}

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

	 // If no open positions, try to open one
	 if(currentPositions == 0)
		 {
			double atr = 0.0;
			double atrBuf[1];
			if(CopyBuffer(handleATR,0,0,1,atrBuf) >= 1) atr = atrBuf[0];
			if(atr <= 0) atr = SymbolInfoDouble(Symbol(), SYMBOL_POINT) * 1000; // fallback small value

			double lot = CalculateLotSize(atr);
			if(lot < MinLot) lot = MinLot;
			if(lot > MaxLot) lot = MaxLot;

				if(buySignal)
				{
				 double price = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
					// Prefer placing SL under recent swing low; fallback to ATR-based SL
					double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
					double sl = swingLow - point*10.0;
					if(!(sl < price)) sl = price - atr * SLMultiplier; // ensure SL is below price
					double tp = price + atr * TPMultiplier;
				 if(trade.Buy(lot, Symbol(), price, sl, tp, "MTF_MACD_Buy"))
						Print("Buy opened: lot=",lot," SL=",sl," TP=",tp);
				 else
						Print("Buy failed: ",GetLastError());
				}
				else if(sellSignal)
				{
				 double price = SymbolInfoDouble(Symbol(), SYMBOL_BID);
					// Prefer placing SL above recent swing high; fallback to ATR-based SL
					double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
					double sl = swingHigh + point*10.0;
					if(!(sl > price)) sl = price + atr * SLMultiplier; // ensure SL is above price
					double tp = price - atr * TPMultiplier;
				 if(trade.Sell(lot, Symbol(), price, sl, tp, "MTF_MACD_Sell"))
						Print("Sell opened: lot=",lot," SL=",sl," TP=",tp);
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

	 // approximate value per point
	 double tickValue = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
	 double tickSize  = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
	 if(tickValue <= 0 || tickSize <= 0)
		 {
			// fallback approximate
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
