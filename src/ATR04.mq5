//+------------------------------------------------------------------+
//| ATR04.mq5 - 実績ベース最適化版                                  +
//| - ATR02の高勝率とATR03の利益率を両立                            +
//| - 統計的に有意な取引数を確保（100+トレード目標）                +
//| - 連敗対策と損失管理の強化                                        +
//| - 短期保有ポジション（日次区切り）                              +
//+------------------------------------------------------------------+
#property copyright "2025"
#property link      ""
#property version   "4.00"
#property strict

#include <Trade/Trade.mqh>

input ENUM_TIMEFRAMES TF = PERIOD_D1;
input int LookbackBars = 20;
input double ATRMultiplier = 1.5;    // ATR基準のSL/TP
input int ATRPeriod = 14;

// リスク管理（ATR02の実績ベース）
input double RiskPercent = 0.3;      // 1トレード0.3%
input double MaxDailyLossPercent = 1.5;  // 1日1.5%
input double RewardMultiplier = 2.0;     // TP = SL × 2.0倍

// フィルター（絞り過ぎない）
input double MinATRFilter = 25.0;    // ATR02より緩く（30→25）
input bool UseTrendFilter = true;
input int TrendPeriod = 50;
input bool UseRSIFilter = false;     // RSIは使わない（削減しすぎた）

// 連敗対策
input int MaxConsecutiveLosses = 4;  // 4連敗でロット減
input double LotReductionPercent = 0.5;  // ロットを50%に削減

// トレーリング（短期保有向け）
input double TrailingStart = 50.0;
input double TrailingDistance = 20.0;
input int MaxPositions = 1;
input int Slippage = 10;
input ulong Magic = 200311;

int handleATR = INVALID_HANDLE;
int handleMA50 = INVALID_HANDLE;
CTrade trade;

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
	 
	 Print("[START] ATR Range Breakout v4 - 実績ベース最適化版");
	 Print("[設定] Risk=", RiskPercent, "% RewardMultiplier=", RewardMultiplier, "倍");
	 return INIT_SUCCEEDED;
	}

void OnDeinit(const int reason) 
	{ 
	 if(handleATR != INVALID_HANDLE) IndicatorRelease(handleATR); 
	 if(handleMA50 != INVALID_HANDLE) IndicatorRelease(handleMA50);
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

	 // Get 20-day range
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

	 // === シグナル ===
	 bool buySignal = (close0 > highestHigh) && buyFilterOK;
	 bool sellSignal = (close0 < lowestLow) && sellFilterOK;

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
		      // SL: ブレイク価格 - ATR × 1.5
		      double sl = close0 - (atrValue * ATRMultiplier);
		      // TP: SLの距離 × 2.0倍
		      double tpDistance = (close0 - sl) * RewardMultiplier;
		      double tp = close0 + tpDistance;
		      
		      if(trade.Buy(lot, Symbol(), ask, sl, tp, "BUY-v4"))
		       {
		        Print("[BUY] ATR=", atrValue, " SL pips=", (close0-sl)/point, " TP pips=", (tp-close0)/point);
		        consecutiveLosses = 0;
		       }
		     }
		    else if(sellSignal)
		     {
		      double sl = close0 + (atrValue * ATRMultiplier);
		      double tpDistance = (sl - close0) * RewardMultiplier;
		      double tp = close0 - tpDistance;
		      
		      if(trade.Sell(lot, Symbol(), bid, sl, tp, "SELL-v4"))
		       {
		        Print("[SELL] ATR=", atrValue, " SL pips=", (sl-close0)/point, " TP pips=", (close0-tp)/point);
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
		  ulong ticket = PositionGetTicket(i);
		  if(ticket > 0 && PositionSelectByTicket(ticket))
		   {
		    if(PositionGetInteger(POSITION_MAGIC) == (long)Magic && PositionGetString(POSITION_SYMBOL) == Symbol())
		     count++;
		   }
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
		  Print("[RESET] Day changed. Daily equity=", dailyStartEquity);
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
		  ulong ticket = PositionGetTicket(i);
		  if(ticket <= 0 || !PositionSelectByTicket(ticket)) continue;
		  if(PositionGetInteger(POSITION_MAGIC) != (long)Magic) continue;
		  if(PositionGetString(POSITION_SYMBOL) != Symbol()) continue;
		  
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
	 double baseRisk = equity * RiskPercent / 100.0;
	 
	 // 連敗時はロット削減
	 double lotAdjustment = 1.0;
	 if(consecutiveLosses >= MaxConsecutiveLosses)
		 {
		  lotAdjustment = LotReductionPercent;
		  Print("[LOSS LIMIT] Consecutive losses=", consecutiveLosses, " Lot reduced to ", (int)(lotAdjustment*100), "%");
		 }
	 
	 double risk = baseRisk * lotAdjustment;
	 
	 double tickVal = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
	 double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
	 
	 if(tickVal <= 0 || atrValue <= 0) return 0.01;
	 
	 // SL距離 = ATR × 1.5
	 double slDistance = atrValue * ATRMultiplier / tickSize;
	 
	 double lot = risk / (slDistance * tickVal);
	 lot = MathFloor(lot / 0.01) * 0.01;
	 
	 if(lot < 0.01) lot = 0.01;
	 if(lot > 10.0) lot = 10.0;
	 
	 return lot;
	}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
	{
	 // ディールタイプが決済の場合のみ処理
	 if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
		 {
		  // マジックナンバーをチェック
		  ulong deal_ticket = trans.deal;
		  if(HistoryDealSelect(deal_ticket))
		    {
		     long deal_magic = HistoryDealGetInteger(deal_ticket, DEAL_MAGIC);
		     if(deal_magic != (long)Magic) return;
		     
		     // 決済による損益のみを対象
		     long deal_entry = HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
		     if(deal_entry == DEAL_ENTRY_OUT)
		       {
		        double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);
		        
		        // 損失判定
		        if(profit < -1.0)
		          {
		           consecutiveLosses++;
		           Print("[LOSS] Deal profit=", profit, " Consecutive losses now: ", consecutiveLosses);
		          }
		        // 利益判定
		        else if(profit > 1.0)
		          {
		           consecutiveLosses = 0;
		           Print("[WIN] Deal profit=", profit, " Reset consecutive losses");
		          }
		       }
		    }
		 }
	}