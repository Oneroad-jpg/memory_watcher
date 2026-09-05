# Memory Watcher

Memory Watcherは、macOS全体のメモリ状態を継続的に記録し、あとから
12時間・24時間・3日の履歴を見返せる軽量なメニューバーアプリです。

本プロジェクトは、Codexによるノンコード開発のアプリです。利用者が
コードを直接記述せず、Codexとの対話で要件定義・実装・検証を進めます。
生成物はSwiftとSwiftUIで実装するネイティブmacOSアプリです。

## ノーコード開発のための習作

Memory Watcherはメモリ履歴を記録するアプリであると同時に、Codexとの
対話を通じて、要件定義から実装・検証・公開まで進めるノーコード開発の
習作です。

ここでいうノーコードとは、ソースコードが存在しないという意味では
ありません。利用者がコードを直接記述せず、目的・制約・工程・完了条件を
自然言語で伝え、CodexがSwiftコード、テスト、Git操作を担当する開発方法を
指します。

この習作では、次の進め方を実践します。

- 実装前に対象機能と対象外機能を固定する
- 各工程に観測可能な完了条件を設定する
- 実測結果とOS標準ツールを照合する
- 工程ごとに1コミットとPull Requestで履歴を残す
- incidentや説明不能な差が発生した場合は、その工程で停止する

この進め方はSwiftやmacOSに限定されず、Java・Python・Windowsアプリなどの
対話型開発にも応用できます。

## v0.1の目的

- Mac全体のメモリ統計を5秒ごとに取得する
- 物理メモリ、使用量、有線、圧縮、キャッシュ、スワップを記録する
- メモリプレッシャーを `UNKNOWN`・`NORMAL`・`WARNING`・`CRITICAL` で記録する
- 履歴をローカルSQLiteへ保存する
- 12時間・24時間・3日のグラフを表示する
- スリープ中の時間を補間せず、空白として表示する
- メニューバーから履歴ウインドウを開く
- ログイン時起動を利用者が切り替えられる

## v0.1で行わないこと

- 通知
- 外向き通信、分析送信、クラウド保存
- プロセス別・アプリ別の解析
- AI機能
- Activity Monitorの数値や連続的な圧力曲線との完全一致

Memory WatcherはActivity Monitorと同じ傾向を観察できることを目標とします。
公開APIから完全一致を保証できない値には、実装時に誤解のない名称と説明を
付けます。

## 対応環境

- macOS 14以降
- Apple SiliconおよびIntel Mac
- 開発環境: Xcode 26系、Swift 6系

## プライバシー

測定値は
`~/Library/Application Support/MemoryWatcher/memory-watcher.sqlite3`
だけに保存します。通知、外向き通信、クラウド同期、分析送信は実装しません。

公開リポジトリには製品のソースコード、テスト、リソース、一般向け文書、
ビルド補助スクリプトだけを保存します。ローカルの開発調整情報、
端末固有パス、認可文字列、受領記録、非公開ログは保存しません。

## 開発状況

v0.1は工程ごとに独立した1コミットとPull Requestで進めます。各工程は
工程表の完了条件を確認してから `main` へマージし、incidentが発生した
場合はそこで停止します。

- 完了: 工程0「要件固定」
- 完了: 工程1「プロジェクト基盤」
- 完了: 工程2「メモリ計測プロトタイプ」
- 完了: 工程3「Activity Monitorとの照合」
- 完了: 工程4「メモリプレッシャー取得」
- 完了: 工程5「SQLite保存」
- 完了: 工程6「常時監視とライフサイクル」
- 完了: 工程7「履歴集約と保存期限」
- 完了: 工程8「履歴グラフ」
- 完了: 工程9「メニューバー統合」
- 完了: 工程10「24時間実運転」
- 完了: 工程11「軽量性・非通信検証」
- 完了: 工程12「アプリ化・最終読戻し」
- v0.1完成
- 完了: 工程13「CPU取得要件と品質の固定」
- 完了: 工程14「Mac全体CPUの保存」
- 完了: 工程15「論理CPU別の保存」
- 完了: 工程16「CPU履歴グラフ」
- 完了: 工程16A「単一ウインドウへの画面統合」
- 完了: 工程17「統合版の最終監査」
- v0.2完成
- 完了: 工程18「表示構成要件と設定契約」
- 工程表: [v0.1確定工程表](docs/Memory_Watcher_v0.1_Final_Implementation_Plan.md)
- 確定要件: [v0.1確定要件](docs/Memory_Watcher_v0.1_Requirements.md)
- 工程10検証記録: [24時間実運転](docs/Phase_10_Verification.md)
- 工程11検証記録: [軽量性・非通信検証](docs/Phase_11_Verification.md)
- 工程12検証記録: [アプリ化・最終読戻し](docs/Phase_12_Verification.md)
- CPU指標定義: [CPU指標定義 v1](docs/CPU_Metric_Definitions_v1.md)
- 工程13検証記録: [CPU取得要件・品質契約](docs/Phase_13_Verification.md)
- 工程14検証記録: [Mac全体CPU保存](docs/Phase_14_Verification.md)
- 工程15検証記録: [論理CPU別保存](docs/Phase_15_Verification.md)
- 工程16検証記録: [CPU履歴グラフ](docs/Phase_16_Verification.md)
- v0.2計画: [CPU・統合画面工程表](docs/Memory_Watcher_v0.2_CPU_and_Unified_Dashboard_Plan.md)
- v0.3計画: [ローカル表示構成工程表](docs/Memory_Watcher_v0.3_Layout_Configuration_Plan.md)
- 表示設定契約: [Dashboard Layout Contract v1](docs/Dashboard_Layout_Contract_v1.md)

## 開発

```sh
swift build
swift test
scripts/build-development-app.sh
open .build/MemoryWatcher.app
scripts/run-measurement-probe.sh 121
scripts/build-release-app.sh 0.1.0 1
scripts/install-release-app.sh 0.1.0
```

外部パッケージには依存しません。Apple SDKとmacOS同梱SQLiteだけを
使用します。
