//+------------------------------------------------------------------+
//| ATR06.mq5 - 強化版シグナルフィルタリング＆リスク管理最適化版      +
//| - ATR05の分析結果に基づく改善                                    +
//| - 勝率向上（41%→50%以上目標）とプロフィットファクター改善      +
//| - 多重フィルタリング＆エントリータイミング最適化                +
//| - 強力なドローダウン制御とポジション管理                        +
//+------------------------------------------------------------------+
#property copyright "2025"
#property link      ""
#property version   "6.00"
#property strict

#include <Trade/Trade.mqh>

input ENUM_TIMEFRAMES TF = PERIOD_D1;
input int LookbackBars = 20;
input double ATRMultiplier = 1.5;    // ATR基準のSL/TP
input int ATRPeriod = 14;

// リスク管理（強化版）
input double RiskPercent = 0.25;     // 1トレード0.25%（より保守的）
input double MaxDailyLossPercent = 1.5;   // 1日1.5%に削減（ドローダウン制御）
input double MaxWeeklyLossPercent = 3.0;  // 1週間3.0%制限
input double RewardMultiplier = 2.0;      // TP = SL × 2倍（より現実的）

// シグナルフィルター（多重化）
input double MinATRFilter = 30.0;    // ATR最小値を上げる
input bool UseTrendFilter = true;
input int TrendPeriod = 50;

// RSIフィルター（強化版）
input bool UseRSIFilter = true;
input int RSIPeriod = 14;
input double RSIUpperLevel = 70.0;   // ↑から下降時のセル制限
input double RSILowerLevel = 30.0;   // ↓から上昇時のバイ制限

// ボリューム/ボラティリティ確認
input bool UseVolatilityConfirmation = true;
input double VolatilityThreshold = 1.2;   // 平均ATRの1.2倍以上で確認

// 連敗対策（強化版）
input int MaxConsecutiveLosses = 1;      // 1連敗でロット減（より保守的）
input double LotReductionPercent = 0.5;  // ロットを50%に削減
input bool UseDynamicLotRecovery = true; // 段階的ロット回復
input int WinCountToRestore = 3;        // 3勝でロット100%に戻す

// トレーリング（強化版）
input double TrailingStart = 50.0;      // トレーリング開始ポイント（高め）
input double TrailingDistance = 20.0;   // トレーリング距離
input int MaxPositions = 1;
input int Slippage = 10;
input ulong Magic = 200613;

// 時間フィルター
input bool UseTimeFilter = true;
input int SessionStartHour = 8;   // GMT/UTC時間で設定
input int SessionEndHour = 20;    // オーバーラップセッションのみ

int handleATR = INVALID_HANDLE;
int handleMA50 = INVALID_HANDLE;
int handleRSI = INVALID_HANDLE;
int handleATRSMA = INVALID_HANDLE;  // 平均ATR
CTrade trade;

double dailyStartEquity = 0;
double weeklyStartEquity = 0;
int consecutiveLosses = 0;
int consecutiveWins = 0;
datetime lastResetTime = 0;
datetime lastWeeklyResetTime = 0;
double currentLotMultiplier = 1.0;

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
		  handleRSI = iRSI(Symbol(), TF, RSIPeriod, PRICE_CLOSE);
		  if(handleRSI == INVALID_HANDLE) return INIT_FAILED;
		 }
	 
	 if(UseVolatilityConfirmation)
		 {
		  handleATRSMA = iMA(Symbol(), TF, 20, 0, MODE_SMA, 0);
		  if(handleATRSMA == INVALID_HANDLE) return INIT_FAILED;
		 }
	 
	 trade.SetExpertMagicNumber(Magic);
	 trade.SetDeviationInPoints(Slippage);
	 
	 dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
	 weeklyStartEquity = dailyStartEquity;
	 lastResetTime = TimeCurrent();
	 lastWeeklyResetTime = TimeCurrent();
	 currentLotMultiplier = 1.0;
	 
	 Print("[START] ATR Range Breakout v6 - 強化版シグナルフィルタリング");
	 Print("[設定] Risk=", RiskPercent, "% MaxDaily=", MaxDailyLossPercent, "% RewardMultiplier=", RewardMultiplier, "倍");
	 Print("[フィルター] MinATR=", MinATRFilter, " UseRSI=", UseRSIFilter, " UseVolatility=", UseVolatilityConfirmation);
	 return INIT_SUCCEEDED;
	}

void OnDeinit(const int reason) 
	{ 
	 if(handleATR != INVALID_HANDLE) IndicatorRelease(handleATR); 
	 if(handleMA50 != INVALID_HANDLE) IndicatorRelease(handleMA50);
	 if(handleRSI != INVALID_HANDLE) IndicatorRelease(handleRSI);
	 if(handleATRSMA != INVALID_HANDLE) IndicatorRelease(handleATRSMA);
	}

//+------------------------------------------------------------------+
void OnTick()
	{
	 CheckDailyReset();
	 CheckWeeklyReset();
	 
	 if(CheckMaxDailyLoss())
		 {
		  Print("[WARNING] Daily loss limit reached. Stopping today's trades.");
		  return;
		 }
	 
	 if(CheckMaxWeeklyLoss())
		 {
		  Print("[WARNING] Weekly loss limit reached. Stopping this week's trades.");
		  return;
		 }
	 
	 double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
	 double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
	 double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);

	 // === 時間フィルター ===
	 if(UseTimeFilter && !IsSessionTime())
		 return;

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
	 
	 // === ボラティリティフィルター（強化版）===
	 if(atrValue < MinATRFilter * point)
		 return;

	 // ボラティリティ確認フィルター
	 if(UseVolatilityConfirmation)
		 {
		  double atrMA[1];
		  if(CopyBuffer(handleATRSMA, 0, 0, 1, atrMA) < 1) return;
		  // 現在のATRが平均ATRの1.2倍以上でないと危険
		  if(atrValue < atrMA[0] * VolatilityThreshold)
		    return;
		 }

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

	 // === RSIフィルター（強化版：極値防止） ===
	 if(UseRSIFilter)
		 {
		  double rsi[1];
		  if(CopyBuffer(handleRSI, 0, 0, 1, rsi) < 1) return;
		  double rsiValue = rsi[0];
		  
		  // 買いシグナル：RSIが高すぎない（過買でない）
		  if(rsiValue > RSIUpperLevel)
		    buyFilterOK = false;
		  
		  // 売りシグナル：RSIが低すぎない（過売でない）
		  if(rsiValue < RSILowerLevel)
		    sellFilterOK = false;
		 }

	 // === シグナル（多重確認） ===
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
		      // TP: SLの距離 × 2倍（より高い目標）
		      double tpDistance = (close0 - sl) * RewardMultiplier;
		      double tp = close0 + tpDistance;
		      
		      if(trade.Buy(lot, Symbol(), ask, sl, tp, "BUY-v6"))
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
		      
		      if(trade.Sell(lot, Symbol(), bid, sl, tp, "SELL-v6"))
		       {
		        Print("[SELL] Lot=", lot, " ATR=", atrValue, " SL pips=", (sl-close0)/point, " TP pips=", (close0-tp)/point);
		        consecutiveLosses = 0;
		       }
		     }
		   }
		 }
	}

//+------------------------------------------------------------------+
bool IsSessionTime()
	{
	 MqlDateTime time_struct;
	 TimeToStruct(TimeCurrent(), time_struct);
	 int current_hour = time_struct.hour;
	 
	 if(SessionStartHour < SessionEndHour)
		 return (current_hour >= SessionStartHour && current_hour < SessionEndHour);
	 else
		 return (current_hour >= SessionStartHour || current_hour < SessionEndHour);
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
void CheckWeeklyReset()
	{
	 MqlDateTime current, last;
	 TimeToStruct(TimeCurrent(), current);
	 TimeToStruct(lastWeeklyResetTime, last);
	 
	 // 月曜日かどうかを確認（day_of_week: 1=月曜日）
	 if(current.day_of_week == 1 && last.day_of_week != 1)
		 {
		  weeklyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
		  lastWeeklyResetTime = TimeCurrent();
		  Print("[WEEKLY RESET] New week started. Weekly equity=", weeklyStartEquity);
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
bool CheckMaxWeeklyLoss()
	{
	 double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
	 double loss = weeklyStartEquity - currentEquity;
	 double lossPercent = (loss / weeklyStartEquity) * 100.0;
	 
	 return (lossPercent >= MaxWeeklyLossPercent);
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
	 
	 // === 連敗時はロット削減（より厳格） ===
	 double lotAdjustment = 1.0;
	 if(consecutiveLosses >= MaxConsecutiveLosses)
		 {
		  lotAdjustment = LotReductionPercent;
		  Print("[WARNING] Consecutive losses=", consecutiveLosses, " Lot reduced to ", 
		        (int)(lotAdjustment*100), "%");
		 }
	 
	 // === 動的ロット回復：段階的に戻す ===
	 if(UseDynamicLotRecovery && consecutiveWins > 0)
	   {
	    if(consecutiveWins >= WinCountToRestore)
	      {
	       lotAdjustment = 1.0;
	       consecutiveWins = 0;  // リセット
	       Print("[RECOVERY] ", WinCountToRestore, " consecutive wins - Lot restored to 100%");
	      }
	    else
	      {
	       // 段階的な回復：勝利数に応じて回復
	       lotAdjustment = MathMin(lotAdjustment + (0.15 * consecutiveWins), 1.0);
	      }
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
		        
		        // 損失判定（より厳格）
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
