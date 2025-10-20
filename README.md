# TrendFollowEA (EA_01)

**Trend-following Expert Advisor for MetaTrader 5**

マルチタイムフレーム分析、一目均衡表（長期）、MACD（短期）、イベントカレンダーフィルタ、トレーリングストップを統合したトレンドフォロー型 EA です。

## 戦略概要

**主要ロジック:**

- **長期足（日足）**: 一目均衡表のクラウドを使いトレンド方向を確認
- **短期足（1 時間足）**: MACD のゴールデンクロス/デッドクロスで エントリ タイミング検出
- **MTF 分析**: 両者が一致した時のみ取引（トレンドフォロー）
- **イベントカレンダー**: 重要経済指標発表前後の取引を自動停止
- **リスク管理**: アカウント% + ATR ベースの動的ロット計算
- **トレーリングストップ**: トレンド継続中に SL/TP を利益方向に自動調整

**開発環境:**

- Windows 上で VSCode でコード編集
- git でバージョン管理
- MetaTrader 5 (MetaEditor) でコンパイル・実行
- Strategy Tester でバックテスト

## EA パラメータ

### 長期足（Ichimoku）設定

```
LongTermTimeframe = PERIOD_D1        // 日足でトレンド確認
TenkanPeriod = 9
KijunPeriod = 26
SenkouSpanBPeriod = 52
```

### 短期足（MACD）設定

```
ShortTermTimeframe = PERIOD_H1       // 1時間足でエントリ
MACDFastPeriod = 12
MACDSlowPeriod = 26
MACDSignalPeriod = 9
```

### マネーマネジメント

```
RiskPercent = 1.0                    // アカウント当たりのリスク %
MaxLot = 1.0
MinLot = 0.01
ATRPeriod = 14
SLMultiplier = 1.0                   // SL 距離倍率 (ATR * SLMultiplier)
TPMultiplier = 2.0                   // TP 距離倍率 (ATR * TPMultiplier)
TrailingStopATRMultiplier = 0.5      // トレーリングストップ距離倍率
```

### トレーリングストップ設定

```
EnableTrailingStop = true             // トレーリングストップ有効化
```

### イベントカレンダー

```
EnableEventFilter = true
EventMarginMinutes = 60              // イベント前後 60 分間は取引停止
```

## 開発・テストフロー

### 1. ローカル開発（Windows）

Windows 上で VSCode を使用して `src/ExampleEA.mq5` を編集します。

```bash
cd C:\Users\haruki\Documents\GitHub\EA_01
git add src/ExampleEA.mq5
git commit -m "Update EA logic"
git push origin main
```

### 2. コンパイル（MetaTrader 5）

MetaTrader 5 を起動し、MetaEditor で EA をコンパイルします。

**手順:**

1. MetaTrader 5 を起動
2. メニュー → ツール → MetaEditor を開く
3. File → Open → `src/ExampleEA.mq5` を選択
4. F5 キーでコンパイル（または Compile ボタン）
5. コンパイル結果を確認（Errors/Warnings が表示される）

### 3. バックテスト（Strategy Tester）

**基本テスト設定:**

- **Symbol**: EURUSD（またはお好みの通貨ペア）
- **Timeframe**: H1（1 時間足）
- **From**: 2023-01-01
- **To**: 2024-12-31
- **Model**: Open prices only（初回試験）→ Every tick（本格テスト）
- **Spread**: 2 pips（ブローカー相応の値に調整）

**手順:**

1. MetaTrader メニュー → ツール → Strategy Tester
2. Expert Advisor に `ExampleEA` を選択
3. Symbol: EURUSD, Period: H1 を設定
4. Start button でテスト実行
5. 結果を確認（リターン、ドローダウン、勝率など）

## 次ステップと改善案

### 実装済み機能

- [x] トレーリング・ストップ機能（トレンド継続中に SL/TP を自動調整）
- [x] MQ5 への移行（ハンドル管理、CTrade クラス使用）
- [x] 逆張り傾向の修正（Ichimoku トレンド判定の改善）
- [x] ストップロス・テイクプロフィットの最適化

### 実装予定機能

- [ ] 複数ポジション管理（高度なリスク管理）
- [ ] 外部イベントカレンダー API 統合（Forex Factory など）
- [ ] パフォーマンス最適化（パラメータ自動調整）
- [ ] ログ機能の拡張（トレード履歴、統計）

### テスト・デバッグ

- バックテスト中に結果がおかしい場合は、パラメータ（FastPeriod, SlowPeriod, ATR 係数）を調整
- Expert Tester の Logs タブでエラーを確認
- Print() ステートメントで Debug 情報を出力

### パラメータ最適化の推奨

**初回テスト設定:**
```
SLMultiplier = 1.0          // リスク:リワード = 1:2 のバランス
TPMultiplier = 2.0
TrailingStopATRMultiplier = 0.5
EnableTrailingStop = true
```

**調整の目安:**
- 逆張り傾向が残る場合: `SLMultiplier` を 0.8-1.2 の範囲で調整
- 利益が伸びない場合: `TPMultiplier` を 2.5-3.0 に増加
- 損切りが早すぎる場合: `TrailingStopATRMultiplier` を 0.3-0.7 に調整

## 開発環境（Windows）

開発は Windows 上で VSCode を使用し、MetaTrader 5 (MetaEditor) でコンパイル・実行します。

### 必須環境

- **Windows 10/11**
- **MetaTrader 5**: 主要ブローカーからダウンロード
- **VSCode**: コード編集用（オプション）
- **Git**: バージョン管理用

### セットアップ手順

1. **MetaTrader 5 のインストール**
   - 主要ブローカー（OANDA, XM, etc.）の公式サイトから MT5 をダウンロード
   - インストール後、MetaEditor を起動して動作確認

2. **VSCode のインストール（推奨）**
   - https://code.visualstudio.com/ からダウンロード
   - MQL5 拡張機能をインストール（オプション）

3. **プロジェクトのクローン**
   ```bash
   cd C:\Users\%USERNAME%\Documents
   git clone https://github.com/Nyao0410/EA_01.git
   cd EA_01
   ```

4. **コンパイル・テスト**
   - MetaEditor で `src/ExampleEA.mq5` を開く
   - F5 でコンパイル
   - Strategy Tester でバックテスト実行
