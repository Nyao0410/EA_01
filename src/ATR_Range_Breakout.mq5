//+------------------------------------------------------------------+
//| ATR_Range_Breakout.mq5 - 新戦略版                                  +
//| ATR + N日間の高値/安値ブレイク                                     +
//| シンプル、ノイズなし、利益優先                                     +
//+------------------------------------------------------------------+
#property copyright "2025"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input ENUM_TIMEFRAMES TF = PERIOD_D1;
input int LookbackBars = 20;        // 過去20日間の高値/安値
input double ATRMultiplier = 1.5;   // ATR倍数
input int ATRPeriod = 14;

input double RiskPercent = 0.5;
input double TrailingStart = 80.0;
input double TrailingDistance = 25.0;
input int MaxPositions = 1;
input int Slippage = 10;
input ulong Magic = 200308;

int handleATR = INVALID_HANDLE;
CTrade trade;

//+------------------------------------------------------------------+
int OnInit()
	{
	 handleATR = iATR(Symbol(), TF, ATRPeriod);
	 if(handleATR == INVALID_HANDLE) return INIT_FAILED;
	 
	 trade.SetExpertMagicNumber(Magic);
	 trade.SetDeviationInPoints(Slippage);
	 Print("[START] ATR Range Breakout v1");
	 return INIT_SUCCEEDED;
	}

void OnDeinit(const int reason) { if(handleATR) IndicatorRelease(handleATR); }

//+------------------------------------------------------------------+
void OnTick()
	{
	 double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
	 double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
	 double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);

	 // Get past N bars high/low (excluding current bar)
	 double highestHigh = iHigh(Symbol(), TF, 1);
	 double lowestLow = iLow(Symbol(), TF, 1);
	 
	 for(int i = 2; i <= LookbackBars; i++)
		 {
			double h = iHigh(Symbol(), TF, i);
			double l = iLow(Symbol(), TF, i);
			if(h > highestHigh) highestHigh = h;
			if(l < lowestLow) lowestLow = l;
		 }

	 // Get ATR for position sizing
	 double atr[1];
	 if(CopyBuffer(handleATR, 0, 0, 1, atr) < 1) return;
	 double atrValue = atr[0];

	 double close0 = iClose(Symbol(), TF, 0);
	 double close1 = iClose(Symbol(), TF, 1);

	 // ===== SIGNAL: Simple Range Breakout =====
	 // 買い: 当日が20日高値を超える
	 bool buySignal = (close0 > highestHigh);
	 
	 // 売り: 当日が20日安値を下回る
	 bool sellSignal = (close0 < lowestLow);

	 // Count positions
	 int pos = 0;
	 for(int i = 0; i < PositionsTotal(); i++)
		 {
			if(PositionGetTicket(i) > 0 && PositionSelectByTicket(PositionGetTicket(i)))
				if(PositionGetInteger(POSITION_MAGIC) == (long)Magic && PositionGetString(POSITION_SYMBOL) == Symbol())
					pos++;
		 }

	 // Update trailing
	 for(int i = PositionsTotal() - 1; i >= 0; i--)
		 {
			if(PositionGetTicket(i) <= 0 || !PositionSelectByTicket(PositionGetTicket(i))) continue;
			if(PositionGetInteger(POSITION_MAGIC) != (long)Magic) continue;
			
			ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
			double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
			double sl = PositionGetDouble(POSITION_SL);
			double tp = PositionGetDouble(POSITION_TP);
			
			if(type == POSITION_TYPE_BUY)
				{
				 if(ask - openPrice >= TrailingStart * point)
					 {
						double newSL = ask - TrailingDistance * point;
						if(newSL > sl) trade.PositionModify(Symbol(), newSL, tp);
					 }
				}
			else
				{
				 if(openPrice - bid >= TrailingStart * point)
					 {
						double newSL = bid + TrailingDistance * point;
						if(newSL < sl) trade.PositionModify(Symbol(), newSL, tp);
					 }
				}
		 }

	 // Entry
	 if(pos == 0)
		 {
			double lot = CalculateLotSize(atrValue, ask, bid);
			
			if(buySignal)
				{
				 // SL: 20日安値とATRの小さい方を選ぶ（ドカン防止）
				 double slByRange = lowestLow - 10*point;
				 double slByATR = ask - (atrValue * 2 / point);  // ATRの2倍を最大SL
				 double sl = (slByATR > slByRange) ? slByATR : slByRange;
				 
				 double tp = ask + (atrValue * ATRMultiplier * 3 / point);  // ATRの3倍
				 if(trade.Buy(lot, Symbol(), ask, sl, tp, "RngBU"))
					 Print("[BUY] RangeBreakUp SL=", sl, " TP=", tp, " ATR=", atrValue);
				}
			else if(sellSignal)
				{
				 // SL: 20日高値とATRの小さい方を選ぶ（ドカン防止）
				 double slByRange = highestHigh + 10*point;
				 double slByATR = bid + (atrValue * 2 / point);  // ATRの2倍を最大SL
				 double sl = (slByATR < slByRange) ? slByATR : slByRange;
				 
				 double tp = bid - (atrValue * ATRMultiplier * 3 / point);  // ATRの3倍
				 if(trade.Sell(lot, Symbol(), bid, sl, tp, "RngBD"))
					 Print("[SELL] RangeBreakDown SL=", sl, " TP=", tp, " ATR=", atrValue);
				}
		 }
	}

//+------------------------------------------------------------------+
double CalculateLotSize(double atrValue, double ask, double bid)
	{
	 double equity = AccountInfoDouble(ACCOUNT_EQUITY);
	 double risk = equity * RiskPercent / 100.0;
	 
	 double tickVal = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
	 double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
	 if(tickVal <= 0) return 0.01;
	 
	 // SLはATRの1.5倍
	 double slDistance = atrValue * ATRMultiplier / tickSize;
	 
	 double lot = risk / (slDistance * tickVal);
	 lot = MathFloor(lot / 0.01) * 0.01;
	 
	 return MathMax(lot, 0.01);
	}

//+------------------------------------------------------------------+
