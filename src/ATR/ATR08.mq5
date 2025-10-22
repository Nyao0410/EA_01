//+------------------------------------------------------------------+
//| ATR08.mq5 - 根本改善版（シグナル品質重視 + 連敗対策強化）       +
//| - ATR07の失敗から学ぶ抜本的改革                                  +
//| - 28%の勝率から45%以上への大幅改善を目指す                      +
//| - ブレイクアウトシグナルの質向上                                +
//| - 複合フィルターとロット削減の強化                              +
//+------------------------------------------------------------------+
#property copyright "2025"
#property link      ""
#property version   "8.00"
#property strict

#include <Trade/Trade.mqh>

input ENUM_TIMEFRAMES TF = PERIOD_D1;
input int LookbackBars = 20;
input double ATRMultiplier = 1.2;    // SLを厳しく（1.5 → 1.2）
input int ATRPeriod = 14;

// リスク管理（強化版）
input double RiskPercent = 0.20;     // 0.25% → 0.20%に削減
input double MaxDailyLossPercent = 1.2;   // 1.5% → 1.2%に削減
input double MaxWeeklyLossPercent = 3.0;  // 3.5% → 3.0%に削減
input double RewardMultiplier = 1.5;      // 1.75 → 1.5（達成しやすく）

// シグナルフィルター（品質重視）
input double MinATRFilter = 25.0;    // 20 → 25（ボラティリティ確保）
input bool UseTrendFilter = false;   // 無効化（逆効果だったため）
input int TrendPeriod = 50;

// RSIフィルター（強化版）
input bool UseRSIFilter = true;
input int RSIPeriod = 14;
input double RSIUpperLevel = 75.0;   // 80 → 75（厳しく）
input double RSILowerLevel = 25.0;   // 20 → 25（厳しく）

// ボラティリティ確認（重要）
input bool UseVolatilityConfirmation = true;   // false → true（有効化）
input double VolatilityThreshold = 0.9;        // 平均ATRの90%以上で確認

// === 複合シグナルフィルター（新規） ===
input bool UseEnhancedSignal = true;       // 複合シグナル確認
input int MAShortPeriod = 14;              // 短期MA
input int MALongPeriod = 50;               // 長期MA

// 連敗対策（抜本的強化）
input int MaxConsecutiveLosses = 1;        // 1連敗で反応（より早期）
input double LotReductionLevel1 = 0.75;    // 1連敗：75%に削減
input double LotReductionLevel2 = 0.50;    // 2連敗：50%に削減
input double LotReductionLevel3 = 0.25;    // 3連敗：25%に削減
input bool UseDynamicLotRecovery = true;
input int WinCountToRestore = 2;           // 2勝で復帰

// トレーリング
input double TrailingStart = 45.0;
input double TrailingDistance = 18.0;
input int MaxPositions = 1;
input int Slippage = 10;
input ulong Magic = 200815;

// 時間フィルター（無効）
input bool UseTimeFilter = false;
input int SessionStartHour = 0;
input int SessionEndHour = 24;

int handleATR = INVALID_HANDLE;
int handleMA50 = INVALID_HANDLE;
int handleRSI = INVALID_HANDLE;
int handleATRSMA = INVALID_HANDLE;
int handleMAShort = INVALID_HANDLE;
int handleMALong = INVALID_HANDLE;
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
	 
	 if(UseEnhancedSignal)
		 {
		  handleMAShort = iMA(Symbol(), TF, MAShortPeriod, 0, MODE_SMA, PRICE_CLOSE);
		  handleMALong = iMA(Symbol(), TF, MALongPeriod, 0, MODE_SMA, PRICE_CLOSE);
		  if(handleMAShort == INVALID_HANDLE || handleMALong == INVALID_HANDLE) 
		    return INIT_FAILED;
		 }
	 
	 trade.SetExpertMagicNumber(Magic);
	 trade.SetDeviationInPoints(Slippage);
	 
	 dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
	 weeklyStartEquity = dailyStartEquity;
	 lastResetTime = TimeCurrent();
	 lastWeeklyResetTime = TimeCurrent();
	 currentLotMultiplier = 1.0;
	 
	 Print("[START] ATR Range Breakout v8 - 根本改善版");
	 Print("[改善] SL厳格化(1.2) + 複合フィルター + 段階削減");
	 Print("[目標] 勝率45%+, PF 1.1+, 連敗制御");
	 return INIT_SUCCEEDED;
	}

void OnDeinit(const int reason) 
	{ 
	 if(handleATR != INVALID_HANDLE) IndicatorRelease(handleATR); 
	 if(handleMA50 != INVALID_HANDLE) IndicatorRelease(handleMA50);
	 if(handleRSI != INVALID_HANDLE) IndicatorRelease(handleRSI);
	 if(handleATRSMA != INVALID_HANDLE) IndicatorRelease(handleATRSMA);
	 if(handleMAShort != INVALID_HANDLE) IndicatorRelease(handleMAShort);
	 if(handleMALong != INVALID_HANDLE) IndicatorRelease(handleMALong);
	}

//+------------------------------------------------------------------+
void OnTick()
	{
	 CheckDailyReset();
	 CheckWeeklyReset();
	 
	 if(CheckMaxDailyLoss())
		 {
		  Print("[WARNING] Daily loss limit reached.");
		  return;
		 }
	 
	 if(CheckMaxWeeklyLoss())
		 {
		  Print("[WARNING] Weekly loss limit reached.");
		  return;
		 }
	 
	 double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
	 double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
	 double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);

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
	 
	 // === ボラティリティフィルター ===
	 if(atrValue < MinATRFilter * point)
		 return;

	 // === ボラティリティ確認（強化） ===
	 if(UseVolatilityConfirmation)
		 {
		  double atrMA[1];
		  if(CopyBuffer(handleATRSMA, 0, 0, 1, atrMA) < 1) return;
		  if(atrValue < atrMA[0] * VolatilityThreshold)
		    return;
		 }

	 double close0 = iClose(Symbol(), TF, 0);
	 
	 // === RSIフィルター（強化版） ===
	 bool buyFilterOK = true;
	 bool sellFilterOK = true;
	 
	 if(UseRSIFilter)
		 {
		  double rsi[1];
		  if(CopyBuffer(handleRSI, 0, 0, 1, rsi) < 1) return;
		  double rsiValue = rsi[0];
		  
		  if(rsiValue > RSIUpperLevel)
		    buyFilterOK = false;
		  if(rsiValue < RSILowerLevel)
		    sellFilterOK = false;
		 }

	 // === 複合シグナル確認（新規） ===
	 if(UseEnhancedSignal)
		 {
		  double maShort[1], maLong[1];
		  if(CopyBuffer(handleMAShort, 0, 0, 1, maShort) < 1) return;
		  if(CopyBuffer(handleMALong, 0, 0, 1, maLong) < 1) return;
		  
		  // 買い：短期MAが長期MAより上
		  if(maShort[0] > maLong[0])
		    buyFilterOK = buyFilterOK && true;  // 強化
		  else
		    buyFilterOK = false;
		  
		  // 売り：短期MAが長期MAより下
		  if(maShort[0] < maLong[0])
		    sellFilterOK = sellFilterOK && true; // 強化
		  else
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
		      double sl = close0 - (atrValue * ATRMultiplier);
		      double tpDistance = (close0 - sl) * RewardMultiplier;
		      double tp = close0 + tpDistance;
		      
		      if(trade.Buy(lot, Symbol(), ask, sl, tp, "BUY-v8"))
		       {
		        Print("[BUY] Lot=", lot, " SL pips=", (close0-sl)/point);
		        consecutiveLosses = 0;
		       }
		     }
		    else if(sellSignal)
		     {
		      double sl = close0 + (atrValue * ATRMultiplier);
		      double tpDistance = (sl - close0) * RewardMultiplier;
		      double tp = close0 - tpDistance;
		      
		      if(trade.Sell(lot, Symbol(), bid, sl, tp, "SELL-v8"))
		       {
		        Print("[SELL] Lot=", lot, " SL pips=", (sl-close0)/point);
		        consecutiveLosses = 0;
		       }
		     }
		   }
		 }
	}

//+------------------------------------------------------------------+
bool IsSessionTime()
	{
	 if(!UseTimeFilter) return true;
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
		    if(PositionGetInteger(POSITION_MAGIC) == (long)Magic && 
		       PositionGetString(POSITION_SYMBOL) == Symbol())
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
		  Print("[RESET] Day changed");
		 }
	}

//+------------------------------------------------------------------+
void CheckWeeklyReset()
	{
	 MqlDateTime current, last;
	 TimeToStruct(TimeCurrent(), current);
	 TimeToStruct(lastWeeklyResetTime, last);
	 
	 if(current.day_of_week == 1 && last.day_of_week != 1)
		 {
		  weeklyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
		  lastWeeklyResetTime = TimeCurrent();
		  Print("[WEEKLY RESET]");
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
	 
	 // === 段階的ロット削減（強化版） ===
	 double lotAdjustment = 1.0;
	 
	 if(consecutiveLosses >= 3)
		 {
		  lotAdjustment = LotReductionLevel3;  // 25%
		  Print("[LOSS3+] Lot=25%");
		 }
	 else if(consecutiveLosses == 2)
		 {
		  lotAdjustment = LotReductionLevel2;  // 50%
		  Print("[LOSS2] Lot=50%");
		 }
	 else if(consecutiveLosses >= 1)
		 {
		  lotAdjustment = LotReductionLevel1;  // 75%
		  Print("[LOSS1] Lot=75%");
		 }
	 
	 // === 段階的ロット回復 ===
	 if(UseDynamicLotRecovery && consecutiveWins > 0)
	   {
	    if(consecutiveWins >= WinCountToRestore)
	      {
	       lotAdjustment = 1.0;
	       consecutiveWins = 0;
	       Print("[RECOVERY] Lot=100%");
	      }
	    else
	      {
	       lotAdjustment = MathMin(lotAdjustment + (0.15 * consecutiveWins), 1.0);
	      }
	   }
	 
	 currentLotMultiplier = lotAdjustment;
	 double risk = baseRisk * lotAdjustment;
	 
	 double tickVal = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
	 double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
	 
	 if(tickVal <= 0 || atrValue <= 0) return 0.01;
	 
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
	 if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
		 {
		  ulong deal_ticket = trans.deal;
		  if(HistoryDealSelect(deal_ticket))
		    {
		     long deal_magic = HistoryDealGetInteger(deal_ticket, DEAL_MAGIC);
		     if(deal_magic != (long)Magic) return;
		     
		     long deal_entry = HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
		     if(deal_entry == DEAL_ENTRY_OUT)
		       {
		        double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);
		        
		        if(profit < -1.0)
		          {
		           consecutiveLosses++;
		           consecutiveWins = 0;
		           Print("[LOSS] #", deal_ticket, " profit=", profit, 
		                 " losses=", consecutiveLosses);
		          }
		        else if(profit > 1.0)
		          {
		           consecutiveLosses = 0;
		           consecutiveWins++;
		           Print("[WIN] #", deal_ticket, " profit=", profit, 
		                 " wins=", consecutiveWins);
		          }
		       }
		    }
		 }
	}
