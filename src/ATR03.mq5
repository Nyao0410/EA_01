//+------------------------------------------------------------------+
//| ATR03.mq5 - 利益率重視版（RR比率最適化）                         +
//| - 利益目標を大きく設定（損失の2-3倍）                            +
//| - より良いエントリーフィルター                                    +
//| - ボラティリティに応じた動的SL/TP調整                            +
//| - 連続損失時の自動ロット削減                                      +
//+------------------------------------------------------------------+
#property copyright "2025"
#property link      ""
#property version   "3.00"
#property strict

#include <Trade/Trade.mqh>

input ENUM_TIMEFRAMES TF = PERIOD_D1;
input int LookbackBars = 20;
input double ATRMultiplier = 1.2;     // SL距離を小さく

// リスク・リワード比率
input double RiskPercent = 0.2;       // 1トレードのリスク（0.2%）
input double RewardRatio = 3.0;       // リワード/リスク = 3.0倍

// フィルター
input double MinATRFilter = 40.0;     // 最小ATR（より厳しく）
input bool UseTrendFilter = true;
input int TrendPeriod = 50;
input bool UseRSIFilter = true;       // RSIで過熱判定
input int RSIPeriod = 14;
input double RSIThreshold = 70;       // 買い過熱/売り過熱閾値

// 制限
input double MaxDailyLossPercent = 1.0;  // 厳しく制限
input double MaxConsecutiveLosses = 3;

// トレーリング（小さく設定）
input double TrailingStart = 30.0;
input double TrailingDistance = 15.0;
input int MaxPositions = 1;
input int Slippage = 10;
input ulong Magic = 200310;

int handleATR = INVALID_HANDLE;
int handleMA50 = INVALID_HANDLE;
int handleRSI = INVALID_HANDLE;
CTrade trade;

double dailyStartEquity = 0;
int consecutiveLosses = 0;
datetime lastResetTime = 0;

//+------------------------------------------------------------------+
int OnInit()
	{
	 handleATR = iATR(Symbol(), TF, 14);
	 if(handleATR == INVALID_HANDLE) return INIT_FAILED;
	 
	 if(UseTrendFilter)
		 {
		  handleMA50 = iMA(Symbol(), TF, TrendPeriod, 0, MODE_SMA, PRICE_CLOSE);
		  if(handleMA50 == INVALID_HANDLE) return INIT_FAILED;
		 }
	 
	 if(UseRSIFilter)
		 {
		  handleRSI = iRSI(Symbol(), TF, RSIPeriod, PRICE_CLOSE);
		  if(handleRSI == INVALID_HANDLE) return INIT_FAILED;
		 }
	 
	 trade.SetExpertMagicNumber(Magic);
	 trade.SetDeviationInPoints(Slippage);
	 
	 dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
	 lastResetTime = TimeCurrent();
	 
	 Print("[START] ATR Range Breakout v3 - 利益率重視版");
	 Print("[設定] Risk=", RiskPercent, "% RewardRatio=", RewardRatio, "倍");
	 return INIT_SUCCEEDED;
	}

void OnDeinit(const int reason) 
	{ 
	 if(handleATR) IndicatorRelease(handleATR); 
	 if(handleMA50) IndicatorRelease(handleMA50);
	 if(handleRSI) IndicatorRelease(handleRSI);
	}

//+------------------------------------------------------------------+
void OnTick()
	{
	 CheckDailyReset();
	 
	 if(CheckMaxDailyLoss())
		 {
		  Print("[WARNING] Daily loss limit reached");
		  return;
		 }
	 
	 double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
	 double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
	 double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);

	 // Get range
	 double highestHigh = iHigh(Symbol(), TF, 1);
	 double lowestLow = iLow(Symbol(), TF, 1);
	 
	 for(int i = 2; i <= LookbackBars; i++)
		 {
		  double h = iHigh(Symbol(), TF, i);
		  double l = iLow(Symbol(), TF, i);
		  if(h > highestHigh) highestHigh = h;
		  if(l < lowestLow) lowestLow = l;
		 }

	 // Get ATR
	 double atr[1];
	 if(CopyBuffer(handleATR, 0, 0, 1, atr) < 1) return;
	 double atrValue = atr[0];
	 
	 // ボラティリティフィルター
	 if(atrValue < MinATRFilter * point)
		 return;

	 double close0 = iClose(Symbol(), TF, 0);
	 
	 // === トレンドフィルター ===
	 bool buyFilterOK = true;
	 bool sellFilterOK = true;
	 
	 if(UseTrendFilter)
		 {
		  double ma50[1];
		  if(CopyBuffer(handleMA50, 0, 0, 1, ma50) < 1) return;
		  double maValue = ma50[0];
		  
		  buyFilterOK = (close0 > maValue);
		  sellFilterOK = (close0 < maValue);
		 }

	 // === RSI過熱フィルター ===
	 bool buyRSIOK = true;
	 bool sellRSIOK = true;
	 
	 if(UseRSIFilter)
		 {
		  double rsi[1];
		  if(CopyBuffer(handleRSI, 0, 0, 1, rsi) < 1) return;
		  double rsiValue = rsi[0];
		  
		  // 買い：RSI < 70（過熱していない）
		  buyRSIOK = (rsiValue < RSIThreshold);
		  
		  // 売り：RSI > 30（過熱していない）
		  sellRSIOK = (rsiValue > (100.0 - RSIThreshold));
		 }

	 // === シグナル ===
	 bool buySignal = (close0 > highestHigh) && buyFilterOK && buyRSIOK;
	 bool sellSignal = (close0 < lowestLow) && sellFilterOK && sellRSIOK;

	 int pos = CountPositions();
	 
	 UpdateTrailing(ask, bid);

	 // === エントリー ===
	 if(pos == 0)
		 {
		  double lot = CalculateLotSize(atrValue, ask, bid);
		  
		  if(lot > 0.01)
		   {
		    if(buySignal)
		     {
		      // SLはATR × 1.2倍
		      double sl = close0 - (atrValue * ATRMultiplier);
		      // TPはSLの3倍
		      double tp = close0 + (atrValue * ATRMultiplier * RewardRatio);
		      double slPips = (close0 - sl) / point;
		      double tpPips = (tp - close0) / point;
		      
		      if(trade.Buy(lot, Symbol(), ask, sl, tp, "BUY-v3"))
		       {
		        Print("[BUY] SL=", slPips, "pips TP=", tpPips, "pips RR=1:", RewardRatio, " ATR=", atrValue);
		        consecutiveLosses = 0;
		       }
		     }
		    else if(sellSignal)
		     {
		      double sl = close0 + (atrValue * ATRMultiplier);
		      double tp = close0 - (atrValue * ATRMultiplier * RewardRatio);
		      double slPips = (sl - close0) / point;
		      double tpPips = (close0 - tp) / point;
		      
		      if(trade.Sell(lot, Symbol(), bid, sl, tp, "SELL-v3"))
		       {
		        Print("[SELL] SL=", slPips, "pips TP=", tpPips, "pips RR=1:", RewardRatio, " ATR=", atrValue);
		        consecutiveLosses = 0;
		       }
		     }
		   }
		 }
	}

//+------------------------------------------------------------------+
int CountPositions()
	{
	 int count = 0;
	 for(int i = 0; i < PositionsTotal(); i++)
		 {
		  if(PositionGetTicket(i) > 0 && PositionSelectByTicket(PositionGetTicket(i)))
		   if(PositionGetInteger(POSITION_MAGIC) == (long)Magic && PositionGetString(POSITION_SYMBOL) == Symbol())
		    count++;
		 }
	 return count;
	}

//+------------------------------------------------------------------+
void CheckDailyReset()
	{
	 MqlDateTime current, last;
	 TimeToStruct(TimeCurrent(), current);
	 TimeToStruct(lastResetTime, last);
	 
	 if(current.day != last.day)
		 {
		  dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
		  consecutiveLosses = 0;
		  lastResetTime = TimeCurrent();
		 }
	}

//+------------------------------------------------------------------+
bool CheckMaxDailyLoss()
	{
	 double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
	 double loss = dailyStartEquity - currentEquity;
	 double lossPercent = (loss / dailyStartEquity) * 100.0;
	 
	 return (lossPercent >= MaxDailyLossPercent);
	}

//+------------------------------------------------------------------+
void UpdateTrailing(double ask, double bid)
	{
	 for(int i = PositionsTotal() - 1; i >= 0; i--)
		 {
		  if(PositionGetTicket(i) <= 0 || !PositionSelectByTicket(PositionGetTicket(i))) continue;
		  if(PositionGetInteger(POSITION_MAGIC) != (long)Magic) continue;
		  
		  ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
		  double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
		  double sl = PositionGetDouble(POSITION_SL);
		  double tp = PositionGetDouble(POSITION_TP);
		  double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
		  
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
	}

//+------------------------------------------------------------------+
double CalculateLotSize(double atrValue, double ask, double bid)
	{
	 double equity = AccountInfoDouble(ACCOUNT_EQUITY);
	 double riskAmount = equity * RiskPercent / 100.0;
	 
	 double tickVal = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
	 double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
	 double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
	 
	 if(tickVal <= 0 || atrValue <= 0) return 0.01;
	 
	 // SL距離 = ATR × 1.2
	 double slDistance = atrValue * ATRMultiplier / tickSize;
	 
	 // ロット = リスク / (SL距離 × ティック値)
	 double lot = riskAmount / (slDistance * tickVal);
	 lot = MathFloor(lot / 0.01) * 0.01;
	 
	 if(lot < 0.01) lot = 0.01;
	 if(lot > 10.0) lot = 10.0;
	 
	 return lot;
	}
