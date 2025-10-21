//+------------------------------------------------------------------+
//| Ichimoku_Simple.mq5 - 最終版                                    +
//| 取引回数よりも「勝率」を重視した安定型                              +
//| クラウドフィルター + 高勝率シグナルのみ                            +
//+------------------------------------------------------------------+
#property copyright "2025"
#property link      ""
#property version   "6.00"
#property strict

#include <Trade/Trade.mqh>

input ENUM_TIMEFRAMES TF = PERIOD_D1;                 // 日足（ノイズ最小）
input int TenkanPeriod = 9;
input int KijunPeriod = 26;
input int SenkouBPeriod = 52;
input int SenkouShift = 26;

// リスク管理
input double RiskPercent = 0.3;
input double SLPoints = 100.0;
input double TPPoints = 200.0;                         // 2:1比
input double TrailingStart = 100.0;
input double TrailingDistance = 30.0;

input int MaxPositions = 1;
input int Slippage = 10;
input ulong Magic = 200306;

int handleIch = INVALID_HANDLE;
CTrade trade;

//+------------------------------------------------------------------+
int OnInit()
	{
	 handleIch = iIchimoku(Symbol(), TF, TenkanPeriod, KijunPeriod, SenkouBPeriod);
	 if(handleIch == INVALID_HANDLE) return INIT_FAILED;
	 
	 trade.SetExpertMagicNumber(Magic);
	 trade.SetDeviationInPoints(Slippage);
	 Print("[START] Ichimoku v6 on D1");
	 return INIT_SUCCEEDED;
	}

void OnDeinit(const int reason) { if(handleIch) IndicatorRelease(handleIch); }

//+------------------------------------------------------------------+
void OnTick()
	{
	 double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
	 double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
	 double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);

	 // Get Ichimoku (3 bars for confirmation)
	 double tenkan[3], kijun[3], senkouA[3], senkouB[3];
	 if(CopyBuffer(handleIch, 0, 0, 3, tenkan) < 3) return;
	 if(CopyBuffer(handleIch, 1, 0, 3, kijun) < 3) return;
	 if(CopyBuffer(handleIch, 2, 0, 3, senkouA) < 3) return;
	 if(CopyBuffer(handleIch, 3, 0, 3, senkouB) < 3) return;

	 double cloudTop = MathMax(senkouA[0], senkouB[0]);
	 double cloudBot = MathMin(senkouA[0], senkouB[0]);
	 double close = iClose(Symbol(), TF, 0);
	 double closePrev = iClose(Symbol(), TF, 1);

	 // ===== SIGNAL: Tenkan/Kijun crossover + Strong Cloud confirmation =====
	 // 買い: クラウド上部を大きく超えている + Tenkan上抜け
	 bool buySignal = (tenkan[1] <= kijun[1]) && (tenkan[0] > kijun[0]) && (close > (cloudTop + 50*point));
	 // 売り: クラウド下部を大きく下回っている + Tenkan下抜け
	 bool sellSignal = (tenkan[1] >= kijun[1]) && (tenkan[0] < kijun[0]) && (close < (cloudBot - 50*point));

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
			double lot = CalculateLotSize();
			
			if(buySignal)
				{
				 double sl = ask - SLPoints * point;
				 double tp = ask + TPPoints * point;
				 if(trade.Buy(lot, Symbol(), ask, sl, tp, "Buy"))
					 Print("[BUY] Entry at ", ask, " SL=", sl, " TP=", tp);
				}
			else if(sellSignal)
				{
				 double sl = bid + SLPoints * point;
				 double tp = bid - TPPoints * point;
				 if(trade.Sell(lot, Symbol(), bid, sl, tp, "Sell"))
					 Print("[SELL] Entry at ", bid, " SL=", sl, " TP=", tp);
				}
		 }
	}

//+------------------------------------------------------------------+
double CalculateLotSize()
	{
	 double equity = AccountInfoDouble(ACCOUNT_EQUITY);
	 double risk = equity * RiskPercent / 100.0;
	 
	 double tickVal = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
	 double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
	 if(tickVal <= 0) return 0.01;
	 
	 double lot = risk / (SLPoints * SymbolInfoDouble(Symbol(), SYMBOL_POINT) * tickVal / tickSize);
	 lot = MathFloor(lot / 0.01) * 0.01;
	 
	 return MathMax(lot, 0.01);
	}

//+------------------------------------------------------------------+
