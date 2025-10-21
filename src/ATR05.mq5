//+------------------------------------------------------------------+
//| ATR05.mq5 - 統計的バランス最適化版                              +
//| - ATR04の分析結果に基づく改善                                    +
//| - 勝率向上（25%→45-55%目標）とドローダウン削減                +
//| - リワード比を1.5xに縮小して現実的なTP設定                     +
//| - ロット管理の動的調整ロジック改善                              +
//+------------------------------------------------------------------+
#property copyright "2025"
#property link      ""
#property version   "5.00"
#property strict

#include <Trade/Trade.mqh>

input ENUM_TIMEFRAMES TF = PERIOD_D1;
input int LookbackBars = 20;
input double ATRMultiplier = 1.5;    // ATR基準のSL/TP
input int ATRPeriod = 14;

// リスク管理（最適化版）
input double RiskPercent = 0.3;      // 1トレード0.3%
input double MaxDailyLossPercent = 2.0;  // 1日2.0%に拡大（リトライ機会を増やす）
input double RewardMultiplier = 1.5;     // TP = SL × 1.5倍（現実的に）

// フィルター（バランス型）
input double MinATRFilter = 28.0;    // 25-30の中間値
input bool UseTrendFilter = true;
input int TrendPeriod = 50;
input double RSIUpperLevel = 75.0;   // RSIが高すぎるときのセル制限
input double RSILowerLevel = 25.0;   // RSIが低すぎるときのバイ制限
input bool UseRSIFilter = true;      // 極値フィルタとして機能

// 連敗対策（強化版）
input int MaxConsecutiveLosses = 2;  // 2連敗でロット減
input double LotReductionPercent = 0.67;  // ロットを67%に削減（50%より少し大きく）
input bool UseDynamicLotRecovery = true;  // 勝利後の段階的ロット回復

// トレーリング
input double TrailingStart = 40.0;
input double TrailingDistance = 15.0;
input int MaxPositions = 1;
input int Slippage = 10;
input ulong Magic = 200312;

int handleATR = INVALID_HANDLE;
int handleMA50 = INVALID_HANDLE;
int handleRSI = INVALID_HANDLE;
CTrade trade;

double dailyStartEquity = 0;
int consecutiveLosses = 0;
int consecutiveWins = 0;
datetime lastResetTime = 0;
double currentLotMultiplier = 1.0;  // ロット乗数

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
	 
	 if(UseRSIFilter)
		 {
		  handleRSI = iRSI(Symbol(), TF, 14, PRICE_CLOSE);
		  if(handleRSI == INVALID_HANDLE) return INIT_FAILED;
		 }
	 
	 trade.SetExpertMagicNumber(Magic);
	 trade.SetDeviationInPoints(Slippage);
	 
	 dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
	 lastResetTime = TimeCurrent();
	 currentLotMultiplier = 1.0;
	 
	 Print("[START] ATR Range Breakout v5 - 統計バランス最適化版");
	 Print("[設定] Risk=", RiskPercent, "% RewardMultiplier=", RewardMultiplier, "倍 MinATR=", MinATRFilter);
	 return INIT_SUCCEEDED;
	}

void OnDeinit(const int reason) 
	{ 
	 if(handleATR != INVALID_HANDLE) IndicatorRelease(handleATR); 
	 if(handleMA50 != INVALID_HANDLE) IndicatorRelease(handleMA50);
	 if(handleRSI != INVALID_HANDLE) IndicatorRelease(handleRSI);
	}

//+------------------------------------------------------------------+
void OnTick()
	{
	 CheckDailyReset();
	 
	 if(CheckMaxDailyLoss())
		 {
		  Print("[WARNING] Daily loss limit reached. Stopping today's trades.");
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
	 
	 // ボラティリティフィルター：ATRが小さすぎたらスキップ
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

	 // === RSIフィルター（極値防止） ===
	 if(UseRSIFilter)
		 {
		  double rsi[1];
		  if(CopyBuffer(handleRSI, 0, 0, 1, rsi) < 1) return;
		  double rsiValue = rsi[0];
		  
		  // 買いシグナルは、RSIが極度に高くない時のみ
		  if(rsiValue > RSIUpperLevel)
		    buyFilterOK = false;
		  
		  // 売りシグナルは、RSIが極度に低くない時のみ
		  if(rsiValue < RSILowerLevel)
		    sellFilterOK = false;
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
		      // TP: SLの距離 × 1.5倍（より現実的）
		      double tpDistance = (close0 - sl) * RewardMultiplier;
		      double tp = close0 + tpDistance;
		      
		      if(trade.Buy(lot, Symbol(), ask, sl, tp, "BUY-v5"))
		       {
		        Print("[BUY] Lot=", lot, " ATR=", atrValue, " SL pips=", (close0-sl)/point, " TP pips=", (tp-close0)/point);
		        consecutiveLosses = 0;
		       }
		     }
		    else if(sellSignal)
		     {
		      double sl = close0 + (atrValue * ATRMultiplier);
		      double tpDistance = (sl - close0) * RewardMultiplier;
		      double tp = close0 - tpDistance;
		      
		      if(trade.Sell(lot, Symbol(), bid, sl, tp, "SELL-v5"))
		       {
		        Print("[SELL] Lot=", lot, " ATR=", atrValue, " SL pips=", (sl-close0)/point, " TP pips=", (close0-tp)/point);
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
		  consecutiveWins = 0;
		  currentLotMultiplier = 1.0;
		  lastResetTime = TimeCurrent();
		  Print("[RESET] Day changed. Daily equity=", dailyStartEquity, " Lot multiplier reset to 1.0");
		 }
	}

//+------------------------------------------------------------------+
bool CheckMaxDailyLoss()
	{
	 double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
	 double loss = dailyStartEquity - currentEquity;
	 double lossPercent = (loss / dailyStartEquity) * 100.0;
	 
	 if(lossPercent >= MaxDailyLossPercent)
	   {
	    return true;
	   }
	 return false;
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
	 
	 // 連敗時はロット削減（段階的）
	 double lotAdjustment = 1.0;
	 if(consecutiveLosses >= MaxConsecutiveLosses)
		 {
		  lotAdjustment = LotReductionPercent;
		  Print("[WARNING] Consecutive losses=", consecutiveLosses, " Lot reduced to ", 
		        (int)(lotAdjustment*100), "%");
		 }
	 
	 // 動的ロット回復：連続勝利で段階的に戻す
	 if(UseDynamicLotRecovery && consecutiveWins > 0)
	   {
	    // 1勝で100%、2勝で100%維持など
	    if(consecutiveWins == 1)
	      lotAdjustment = MathMin(lotAdjustment * 1.5, 1.0);  // 150%に向かって回復
	   }
	 
	 currentLotMultiplier = lotAdjustment;
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
	 // ディール追加イベントを検出
	 if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
		 {
		  ulong deal_ticket = trans.deal;
		  if(HistoryDealSelect(deal_ticket))
		    {
		     long deal_magic = HistoryDealGetInteger(deal_ticket, DEAL_MAGIC);
		     if(deal_magic != (long)Magic) return;
		     
		     // 決済取引をチェック
		     long deal_entry = HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
		     if(deal_entry == DEAL_ENTRY_OUT)
		       {
		        double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);
		        
		        // 損失判定
		        if(profit < -1.0)
		          {
		           consecutiveLosses++;
		           consecutiveWins = 0;
		           Print("[LOSS] Deal #", deal_ticket, " profit=", profit, 
		                 " Consecutive losses: ", consecutiveLosses);
		          }
		        // 利益判定
		        else if(profit > 1.0)
		          {
		           consecutiveLosses = 0;
		           consecutiveWins++;
		           Print("[WIN] Deal #", deal_ticket, " profit=", profit, 
		                 " Consecutive wins: ", consecutiveWins);
		          }
		       }
		    }
		 }
	}
