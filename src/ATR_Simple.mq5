//+------------------------------------------------------------------+
//| ATR_Simple.mq5 - シンプル取引版                                    +
//| 20日間の高値/安値ブレイク + ATRストップ                             +
//| ノイズ除外、シンプル、取引確実                                     +
//+------------------------------------------------------------------+
#property copyright "2025"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

// ===== 入力パラメータ =====
input ENUM_TIMEFRAMES TF = PERIOD_D1;           // タイムフレーム
input int LookbackBars = 20;                    // 過去N日間の高値/安値
input double ATRMultiplier = 1.5;               // ATRストップ倍数
input int ATRPeriod = 14;                       // ATR周期

input double RiskPercent = 0.25;                // リスク比率
input double RewardMultiplier = 1.5;            // リワード倍数（TP計算用）
input double TrailingStart = 80.0;              // トレーリング開始（pips）
input double TrailingDistance = 20.0;           // トレーリング距離（pips）
input int MaxPositions = 1;                     // 最大ポジション数
input int Slippage = 10;                        // スリッページ
input ulong Magic = 200915;                     // マジックナンバー

// ===== グローバル変数 =====
int handleATR = INVALID_HANDLE;
CTrade trade;
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
//| 初期化                                                             +
//+------------------------------------------------------------------+
int OnInit()
{
    // ATRハンドル取得
    handleATR = iATR(Symbol(), TF, ATRPeriod);
    if(handleATR == INVALID_HANDLE)
    {
        Print("[ERROR] ATR indicator handle failed");
        return INIT_FAILED;
    }
    
    // トレード設定
    trade.SetExpertMagicNumber(Magic);
    trade.SetDeviationInPoints(Slippage);
    
    Print("[START] ATR_Simple EA initialized");
    Print("  Symbol: ", Symbol());
    Print("  Timeframe: ", EnumToString(TF));
    Print("  Lookback: ", LookbackBars, " bars");
    Print("  ATR Period: ", ATRPeriod, ", Multiplier: ", ATRMultiplier);
    Print("  Risk: ", RiskPercent, "%, Reward: ", RewardMultiplier, "x");
    
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 終了処理                                                           +
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(handleATR != INVALID_HANDLE)
        IndicatorRelease(handleATR);
    
    Print("[END] ATR_Simple EA deinitialized");
}

//+------------------------------------------------------------------+
//| メインロジック                                                     +
//+------------------------------------------------------------------+
void OnTick()
{
    // 現在のバーが完成したか確認（ティック1回目のみ処理）
    datetime currentBarTime = iTime(Symbol(), TF, 0);
    if(currentBarTime == lastBarTime)
        return;  // 同じバー内なら処理スキップ
    
    lastBarTime = currentBarTime;
    
    // ===== 必要なデータ取得 =====
    double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
    double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
    double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
    
    // 前のバーの高値・安値（確定した値）
    double prevClose = iClose(Symbol(), TF, 1);
    double prevOpen = iOpen(Symbol(), TF, 1);
    
    // 過去N日間の高値・安値を取得
    double highestHigh = iHigh(Symbol(), TF, 1);
    double lowestLow = iLow(Symbol(), TF, 1);
    
    for(int i = 2; i <= LookbackBars; i++)
    {
        double h = iHigh(Symbol(), TF, i);
        double l = iLow(Symbol(), TF, i);
        
        if(h > highestHigh)
            highestHigh = h;
        if(l < lowestLow)
            lowestLow = l;
    }
    
    // ATR取得（確定値）
    double atr[1];
    if(CopyBuffer(handleATR, 0, 1, 1, atr) < 1)
    {
        Print("[ERROR] Failed to copy ATR buffer");
        return;
    }
    double atrValue = atr[0];
    
    // ===== シグナル生成（前バーのデータで判定） =====
    // ブレイクアップ: 前のバーが20日高値を上回った
    bool buySignal = (prevClose > highestHigh && prevOpen <= highestHigh);
    
    // ブレイクダウン: 前のバーが20日安値を下回った
    bool sellSignal = (prevClose < lowestLow && prevOpen >= lowestLow);
    
    // DEBUG
    if(buySignal || sellSignal)
    {
        Print("[SIGNAL] Bar #", iBarShift(Symbol(), TF, currentBarTime));
        Print("  highestHigh=", NormalizeDouble(highestHigh, 5));
        Print("  lowestLow=", NormalizeDouble(lowestLow, 5));
        Print("  prevClose=", NormalizeDouble(prevClose, 5));
        Print("  ATR=", NormalizeDouble(atrValue, 5));
        if(buySignal) Print("  -> BUY SIGNAL");
        if(sellSignal) Print("  -> SELL SIGNAL");
    }
    
    // ===== ポジション数カウント =====
    int posCount = 0;
    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionGetTicket(i) <= 0)
            continue;
        if(!PositionSelectByTicket(PositionGetTicket(i)))
            continue;
        if(PositionGetInteger(POSITION_MAGIC) != (long)Magic)
            continue;
        if(PositionGetString(POSITION_SYMBOL) != Symbol())
            continue;
        
        posCount++;
    }
    
    // ===== トレーリングストップ更新 =====
    UpdateTrailingStops(ask, bid, point);
    
    // ===== エントリー処理 =====
    if(posCount < MaxPositions)
    {
        double lot = CalculateLotSize(atrValue, ask, bid, point);
        
        if(lot > 0)
        {
            if(buySignal)
            {
                double sl = lowestLow - 5 * point;  // 20日安値 - 5pips
                double tp = ask + (atrValue * RewardMultiplier / point) * point;
                
                if(trade.Buy(lot, Symbol(), ask, sl, tp, "RNG_BUY"))
                {
                    Print("[ENTRY] BUY executed");
                    Print("  Lot: ", lot);
                    Print("  Entry: ", NormalizeDouble(ask, 5));
                    Print("  SL: ", NormalizeDouble(sl, 5));
                    Print("  TP: ", NormalizeDouble(tp, 5));
                }
                else
                {
                    Print("[ERROR] BUY order failed. Code: ", GetLastError());
                }
            }
            else if(sellSignal)
            {
                double sl = highestHigh + 5 * point;  // 20日高値 + 5pips
                double tp = bid - (atrValue * RewardMultiplier / point) * point;
                
                if(trade.Sell(lot, Symbol(), bid, sl, tp, "RNG_SELL"))
                {
                    Print("[ENTRY] SELL executed");
                    Print("  Lot: ", lot);
                    Print("  Entry: ", NormalizeDouble(bid, 5));
                    Print("  SL: ", NormalizeDouble(sl, 5));
                    Print("  TP: ", NormalizeDouble(tp, 5));
                }
                else
                {
                    Print("[ERROR] SELL order failed. Code: ", GetLastError());
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| トレーリングストップ更新                                            +
//+------------------------------------------------------------------+
void UpdateTrailingStops(double ask, double bid, double point)
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetTicket(i) <= 0)
            continue;
        if(!PositionSelectByTicket(PositionGetTicket(i)))
            continue;
        if(PositionGetInteger(POSITION_MAGIC) != (long)Magic)
            continue;
        if(PositionGetString(POSITION_SYMBOL) != Symbol())
            continue;
        
        ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        double currentSL = PositionGetDouble(POSITION_SL);
        double currentTP = PositionGetDouble(POSITION_TP);
        
        if(type == POSITION_TYPE_BUY)
        {
            // 利益がTrailingStart以上なら、SLを更新
            if(ask - openPrice >= TrailingStart * point)
            {
                double newSL = ask - TrailingDistance * point;
                if(newSL > currentSL)
                {
                    if(trade.PositionModify(Symbol(), newSL, currentTP))
                    {
                        Print("[TRAILING] BUY SL updated to ", NormalizeDouble(newSL, 5));
                    }
                }
            }
        }
        else  // SELL
        {
            // 利益がTrailingStart以上なら、SLを更新
            if(openPrice - bid >= TrailingStart * point)
            {
                double newSL = bid + TrailingDistance * point;
                if(newSL < currentSL)
                {
                    if(trade.PositionModify(Symbol(), newSL, currentTP))
                    {
                        Print("[TRAILING] SELL SL updated to ", NormalizeDouble(newSL, 5));
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| ロット計算                                                         +
//+------------------------------------------------------------------+
double CalculateLotSize(double atrValue, double ask, double bid, double point)
{
    if(atrValue <= 0)
        return 0;
    
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    if(equity <= 0)
        return 0;
    
    // リスク金額 = エクイティ × リスク比率
    double riskAmount = equity * RiskPercent / 100.0;
    
    // 1ロットあたりの値動き
    double tickValue = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
    
    if(tickValue <= 0 || tickSize <= 0)
    {
        Print("[WARNING] Tick info invalid. Using default lot 0.01");
        return 0.01;
    }
    
    // ストップロス距離（pips）= ATR × 倍数
    double slDistance = atrValue * ATRMultiplier / tickSize;
    
    // ロット数 = リスク金額 / (SL距離 × ティック価値)
    double lot = riskAmount / (slDistance * tickValue);
    
    // ロット数を0.01単位に調整
    lot = MathFloor(lot / 0.01) * 0.01;
    
    // 最小ロットサイズ確認
    double minLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
    
    if(lot < minLot)
        lot = minLot;
    if(lot > maxLot)
        lot = maxLot;
    
    return lot;
}
//+------------------------------------------------------------------+
