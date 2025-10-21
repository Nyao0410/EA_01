//+------------------------------------------------------------------+
//| Ichimoku_Breakout.mq5 - 抜け売買型                                +
//| クラウドブレイクアウト + 構造的SL（前日高値/安値）                 +
//+------------------------------------------------------------------+
#property copyright "2025"
#property link      ""
#property version   "7.00"
#property strict

#include <Trade/Trade.mqh>

input ENUM_TIMEFRAMES TF = PERIOD_D1;
input int TenkanPeriod = 9;
input int KijunPeriod = 26;
input int SenkouBPeriod = 52;
input int SenkouShift = 26;

input double RiskPercent = 0.5;
input double TrailingStart = 100.0;
input double TrailingDistance = 30.0;
input int MaxPositions = 1;
input int Slippage = 10;
input ulong Magic = 200307;

int handleIch = INVALID_HANDLE;
CTrade trade;

//+------------------------------------------------------------------+
int OnInit()
	{
	 handleIch = iIchimoku(Symbol(), TF, TenkanPeriod, KijunPeriod, SenkouBPeriod);
	 if(handleIch == INVALID_HANDLE) return INIT_FAILED;
	 
	 trade.SetExpertMagicNumber(Magic);
	 trade.SetDeviationInPoints(Slippage);
	 Print("[START] Ichimoku Breakout v7");
	 return INIT_SUCCEEDED;
	}

void OnDeinit(const int reason) { if(handleIch) IndicatorRelease(handleIch); }

//+------------------------------------------------------------------+
void OnTick()
	{
	 double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
	 double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
	 double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);

	 // Get Ichimoku (2 bars: current + previous)
	 double tenkan[2], kijun[2], senkouA[2], senkouB[2];
	 if(CopyBuffer(handleIch, 0, 0, 2, tenkan) < 2) return;
	 if(CopyBuffer(handleIch, 1, 0, 2, kijun) < 2) return;
	 if(CopyBuffer(handleIch, 2, 0, 2, senkouA) < 2) return;
	 if(CopyBuffer(handleIch, 3, 0, 2, senkouB) < 2) return;

	 double cloudTop0 = MathMax(senkouA[0], senkouB[0]);
	 double cloudBot0 = MathMin(senkouA[0], senkouB[0]);
	 double cloudTop1 = MathMax(senkouA[1], senkouB[1]);
	 double cloudBot1 = MathMin(senkouA[1], senkouB[1]);

	 double close0 = iClose(Symbol(), TF, 0);
	 double close1 = iClose(Symbol(), TF, 1);
	 double high1 = iHigh(Symbol(), TF, 1);
	 double low1 = iLow(Symbol(), TF, 1);

	 // ===== SIGNAL: Cloud Breakout Only =====
	 // 買い: 前日がクラウド内 or 下 → 当日がクラウド上を抜ける
	 bool buySignal = false;
	 if((close1 <= cloudTop1) && (close0 > cloudTop0))
		 {
			buySignal = true;
		 }

	 // 売り: 前日がクラウド内 or 上 → 当日がクラウド下を抜ける
	 bool sellSignal = false;
	 if((close1 >= cloudBot1) && (close0 < cloudBot0))
		 {
			sellSignal = true;
		 }

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
			double lot = CalculateLotSize(high1, low1, ask, bid);
			
			if(buySignal)
				{
				 double sl = low1 - 20*point;  // 前日安値の20pips下 = もっとタイトSL
				 double tp = ask + 300*point;  // 固定TP: 300pips（トレーリングで伸ばす）
				 if(trade.Buy(lot, Symbol(), ask, sl, tp, "CloudBU"))
					 Print("[BUY] CloudBreakUp SL=", sl);
				}
			else if(sellSignal)
				{
				 double sl = high1 + 20*point;  // 前日高値の20pips上 = もっとタイトSL
				 double tp = bid - 300*point;  // 固定TP: 300pips（トレーリングで伸ばす）
				 if(trade.Sell(lot, Symbol(), bid, sl, tp, "CloudBD"))
					 Print("[SELL] CloudBreakDown SL=", sl);
				}
		 }
	}

//+------------------------------------------------------------------+
double CalculateLotSize(double high1, double low1, double ask, double bid)
	{
	 double equity = AccountInfoDouble(ACCOUNT_EQUITY);
	 double risk = equity * RiskPercent / 100.0;
	 
	 double tickVal = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
	 double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
	 if(tickVal <= 0) return 0.01;
	 
	 // SLを前日の高値/安値に基づいて計算
	 double slDistance = high1 - low1;  // 前日のレンジ幅
	 
	 double lot = risk / (slDistance * tickVal / tickSize);
	 lot = MathFloor(lot / 0.01) * 0.01;
	 
	 return MathMax(lot, 0.01);
	}

//+------------------------------------------------------------------+
