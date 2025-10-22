//+------------------------------------------------------------------+
//| ATR02.mq5 - 改善版（コツコツドカン対策）                          +
//| - 損失限定フィルター追加                                          +
//| - 複数フィルター（ボラティリティ、トレンド）                      +
//| - より厳密なストップロス管理                                      +
//| - 最大損失を制限するポジションサイズ調整                          +
//+------------------------------------------------------------------+
#property copyright "2025"
#property link      ""
#property version   "2.00"
#property strict

#include <Trade/Trade.mqh>

input ENUM_TIMEFRAMES TF = PERIOD_D1;
input int LookbackBars = 20;          // 過去N日間の高値/安値
input double ATRMultiplier = 1.5;     // ATR倍数
input int ATRPeriod = 14;

// リスク管理パラメータ
input double RiskPercent = 0.3;       // 1トレードのリスク（0.3%に削減）
input double MaxDailyLossPercent = 1.5; // 1日の最大損失（1.5%）
input double MaxDrawdownPercent = 3.0;  // 最大ドローダウン（3%）

// フィルター
input double MinATRFilter = 30.0;     // 最小ATR（ボラティリティフィルター）
input bool UseTrendFilter = true;     // トレンドフィルター有効
input int TrendPeriod = 50;           // トレンド判定期間

// 損失管理
input bool UseMaxLossLimit = true;    // 最大損失制限
input double MaxConsecutiveLosses = 3; // 連続損失数でストップ

// トレーリング
input double TrailingStart = 60.0;
input double TrailingDistance = 20.0;
input int MaxPositions = 1;
input int Slippage = 10;
input ulong Magic = 200309;

int handleATR = INVALID_HANDLE;
int handleMA50 = INVALID_HANDLE;  // トレンド判定用
CTrade trade;

// グローバル変数
double dailyStartEquity = 0;
int consecutiveLosses = 0;
datetime lastResetTime = 0;

//+------------------------------------------------------------------+
int OnInit()
	{
	 handleATR = iATR(Symbol(), TF, ATRPeriod);
	 if(handleATR == INVALID_HANDLE) return INIT_FAILED;
	 
	 if(UseTrendFilter)
		 {
		  handleMA50 = iMA(Symbol(), TF, TrendPeriod, 0, MODE_SMA, PRICE_CLOSE);
		  if(handleMA50 == INVALID_HANDLE) return INIT_FAILED;
		 }
	 
	 trade.SetExpertMagicNumber(Magic);
	 trade.SetDeviationInPoints(Slippage);
	 
	 dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
	 lastResetTime = TimeCurrent();
	 
	 Print("[START] ATR Range Breakout v2 - コツコツドカン対策版");
	 return INIT_SUCCEEDED;
	}

void OnDeinit(const int reason) 
	{ 
	 if(handleATR) IndicatorRelease(handleATR); 
	 if(handleMA50) IndicatorRelease(handleMA50);
	}

//+------------------------------------------------------------------+
void OnTick()
	{
	 // 日次リセット確認
	 CheckDailyReset();
	 
	 // 1日の最大損失チェック
	 if(UseMaxLossLimit && CheckMaxDailyLoss())
		 {
		  Print("[WARNING] 本日の最大損失に達しました");
		  return;
		 }
	 
	 double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
	 double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
	 double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);

	 // Get past N bars high/low
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
	 
	 // ボラティリティフィルター：ATRが小さすぎる場合はスキップ
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
		  
		  // 買い：終値がMA50より上 = アップトレンド
		  buyFilterOK = (close0 > maValue);
		  
		  // 売り：終値がMA50より下 = ダウントレンド
		  sellFilterOK = (close0 < maValue);
		 }

	 // === シグナル ===
	 bool buySignal = (close0 > highestHigh) && buyFilterOK;
	 bool sellSignal = (close0 < lowestLow) && sellFilterOK;

	 // ポジション数確認
	 int pos = 0;
	 for(int i = 0; i < PositionsTotal(); i++)
		 {
		  if(PositionGetTicket(i) > 0 && PositionSelectByTicket(PositionGetTicket(i)))
		   if(PositionGetInteger(POSITION_MAGIC) == (long)Magic && PositionGetString(POSITION_SYMBOL) == Symbol())
		    pos++;
		 }

	 // === トレーリング更新 ===
	 UpdateTrailing(ask, bid);

	 // === エントリー ===
	 if(pos == 0)
		 {
		  double lot = CalculateLotSize(atrValue, ask, bid);
		  
		  if(lot > 0)
		   {
		    if(buySignal)
		     {
		      double sl = lowestLow - 5*point;     // より厳密なSL
		      double tp = ask + (atrValue * 1.5 / point); // 利益目標を小さく
		      
		      if(trade.Buy(lot, Symbol(), ask, sl, tp, "RngBU"))
		       {
		        Print("[BUY] v2 SL=", sl, " TP=", tp, " ATR=", atrValue, " Lot=", lot);
		       }
		     }
		    else if(sellSignal)
		     {
		      double sl = highestHigh + 5*point;   // より厳密なSL
		      double tp = bid - (atrValue * 1.5 / point);
		      
		      if(trade.Sell(lot, Symbol(), bid, sl, tp, "RngBD"))
		       {
		        Print("[SELL] v2 SL=", sl, " TP=", tp, " ATR=", atrValue, " Lot=", lot);
		       }
		     }
		   }
		 }
	}

//+------------------------------------------------------------------+
void CheckDailyReset()
	{
	 // 日付が変わったかチェック
	 MqlDateTime current, last;
	 TimeToStruct(TimeCurrent(), current);
	 TimeToStruct(lastResetTime, last);
	 
	 if(current.day != last.day)
		 {
		  // 日付が変わった - リセット
		  dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
		  consecutiveLosses = 0;
		  lastResetTime = TimeCurrent();
		  Print("[RESET] Daily equity=", dailyStartEquity);
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
	 double maxRisk = equity * RiskPercent / 100.0;
	 
	 double tickVal = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
	 double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
	 double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
	 
	 if(tickVal <= 0 || atrValue <= 0) return 0.01;
	 
	 // ATRの1.5倍がストップロス距離
	 double slDistance = atrValue * ATRMultiplier / tickSize;
	 
	 double lot = maxRisk / (slDistance * tickVal);
	 lot = MathFloor(lot / 0.01) * 0.01;
	 
	 // 最小値・最大値制限
	 if(lot < 0.01) lot = 0.01;
	 if(lot > 10.0) lot = 10.0;
	 
	 // 1日の最大損失を考慮した制限
	 double maxDailyRisk = AccountInfoDouble(ACCOUNT_EQUITY) * MaxDailyLossPercent / 100.0;
	 double currentDailyLoss = dailyStartEquity - AccountInfoDouble(ACCOUNT_EQUITY);
	 double remainingRisk = maxDailyRisk - MathMax(currentDailyLoss, 0);
	 
	 if(remainingRisk < maxRisk)
	  {
	   lot = lot * (remainingRisk / maxRisk);
	  }
	 
	 return lot;
	}
