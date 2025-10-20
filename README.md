# TrendFollowEA (EA_01)

**Trend-following Expert Advisor for MetaTrader 4**

マルチタイムフレーム分析、一目均衡表（長期）、MACD（短期）、イベントカレンダーフィルタを統合したトレンドフォロー型 EA です。

## 戦略概要

**主要ロジック:**

- **長期足（日足）**: 一目均衡表のクラウドを使いトレンド方向を確認
- **短期足（1 時間足）**: MACD のゴールデンクロス/デッドクロスで エントリ タイミング検出
- **MTF 分析**: 両者が一致した時のみ取引（トレンドフォロー）
- **イベントカレンダー**: 重要経済指標発表前後の取引を自動停止
- **リスク管理**: アカウント% + ATR ベースの動的ロット計算

**開発環境:**

- macOS 上で VSCode でコード編集
- git でバージョン管理
- Windows / UTC 上の MetaTrader 4 (MetaEditor) でコンパイル・実行
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
```

### イベントカレンダー

```
EnableEventFilter = true
EventMarginMinutes = 60              // イベント前後 60 分間は取引停止
```

## 開発・テストフロー

### 1. ローカル開発（Mac）

macOS 上で VSCode を使用して `src/TrendFollowEA.mq4` を編集します。

```bash
cd /Users/haruki/Documents/Programing/Play/EA_01
git add src/ExampleEA.mq4
git commit -m "Update EA logic"
git push origin main
```

### 2. コンパイル（Windows / UTM）

Windows 上の MetaTrader 4 を起動し、MetaEditor で EA をコンパイルします。

**手順:**

1. MetaTrader 4 を起動
2. メニュー → ツール → MetaEditor を開く
3. File → Open → `src/ExampleEA.mq4` を選択
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
2. Expert Advisor に `TrendFollowEA` を選択
3. Symbol: EURUSD, Period: H1 を設定
4. Start button でテスト実行
5. 結果を確認（リターン、ドローダウン、勝率など）

## 次ステップと改善案

### 実装予定機能

- [ ] トレーリング・ストップ機能
- [ ] 複数ポジション管理（高度なリスク管理）
- [ ] 外部イベントカレンダー API 統合（Forex Factory など）
- [ ] パフォーマンス最適化（パラメータ自動調整）
- [ ] ログ機能の拡張（トレード履歴、統計）

### テスト・デバッグ

- バックテスト中に結果がおかしい場合は、パラメータ（FastPeriod, SlowPeriod, ATR 係数）を調整
- Expert Tester の Logs タブでエラーを確認
- Print() ステートメントで Debug 情報を出力

## 開発環境（Windows / UTM）

開発は macOS で行い、コンパイルと実行は Windows 上の MetaTrader 4 (MetaEditor) で行います。代表的な選択肢:

- Virtual Machine (VirtualBox, VMware, Parallels)

  - Pros: 完全な Windows 環境、MetaTrader の互換性が高い
  - Cons: ライセンス（Windows）、リソース多め、Parallels は有料

- CrossOver / Wine

  - Pros: 追加で Windows ライセンスは不要、軽量
  - Cons: 動作しない機能や互換性問題が起きる可能性あり（MetaEditor のバージョン依存）

- リモート Windows（RDP / リモートデスクトップ / クラウド VM）
  - Pros: 手軽に始められる、クラウドだと常時稼働が可能
  - Cons: ネットワーク依存、費用が継続する

## 推奨

初めてで互換性を重視する場合は、VirtualBox/VMware/Parallels 上に公式の Windows を入れて MetaTrader 4 を使う方法を推奨します。軽く試したい場合は CrossOver を試す選択肢もあります。

## 簡易セットアップ手順（Mac -> VirtualBox -> Windows -> MT4）

1. Homebrew をインストール（未インストールなら）
   - /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
2. VirtualBox をインストール
   - brew install --cask virtualbox
3. Windows ISO を用意（Microsoft のサイトから Evaluation ISO が取得可能）
4. VirtualBox に新規 VM を作成し、ISO から Windows をインストール
5. Windows 内にブラウザで MetaTrader 4 をダウンロードしてインストール
6. MetaEditor で`src/ExampleEA.mq4`を開き、コンパイルして実行

詳細なコマンドと注意点は後で個別に記載します。

## 詳細セットアップ例 1: VirtualBox を使う（推奨）

前提: macOS 上で仮想の Windows を作成し、MetaTrader 4 をインストールして動かします。

手順の概要:

1. Homebrew を使って VirtualBox をインストール

   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   brew update
   brew install --cask virtualbox
   ```

2. Windows 10/11 の ISO を取得

   - Microsoft の公式サイトから評価用 ISO をダウンロード

3. VirtualBox で新規仮想マシンを作成

   - メモリやディスクサイズを設定（例: 4GB RAM, 50GB disk）
   - 取得した ISO を使ってインストール

4. Windows 起動後、Chrome/Edge で MetaTrader 4 をダウンロード

   - 主要ブローカーや MetaQuotes の配布先から MT4 を取得

5. MetaEditor で `src/ExampleEA.mq4` を開き、コンパイル・テスト

注意点:

- Parallels はパフォーマンス良好だが有料。Apple Silicon の場合は Parallels が動作しやすい。
- VirtualBox は無料だが、Apple Silicon (M1/M2) では公式サポートが限定的。

## 詳細セットアップ例 2: CrossOver (Wine ベース) を試す（軽量）

CrossOver は Wine をベースにした商用互換レイヤーで、Windows アプリを macOS 上で直接動かせる場合があります。MetaTrader 4 を試すのに便利ですが、完全な互換性は保証されません。

手順の概要:

1. CrossOver の試用版をダウンロードしてインストール

   - https://www.codeweavers.com/crossover

2. CrossOver から新しいボトルを作成し、ブラウザ経由で MT4 をインストール

3. MetaTrader 内の MetaEditor を起動して、`src/ExampleEA.mq4` を開いてコンパイルを試す

注意点:

- エディタ周りやデバッグ機能で互換性問題が出る可能性がある。
- うまく動かない場合は VM に切り替えることを検討する。

## 比較まとめと次の推奨アクション

短い比較:

- VirtualBox/VMware/Parallels: 互換性 ◎、リソース ×、Windows ライセンス必要
- CrossOver/Wine: 軽量、互換性 △、試行的に有用
- リモート/クラウド: 管理や常時稼働に便利、コストが継続

推奨アクション（初回）:

1. まずは VirtualBox + Windows の VM を作って MT4 を動かす（互換性優先）
2. もし Mac が Apple Silicon で VirtualBox が難しい場合は Parallels（有料）を検討
3. 軽く試すだけなら CrossOver を試す

次に私ができること:

- あなたの Mac が Intel か Apple Silicon か教えてください。それに基づいて最適な手順を用意します。
- VirtualBox の具体的なコマンドや、VM 作成テンプレート（設定例）を用意します。
