# Memory Watcher

Memory Watcherは、macOS全体のメモリ状態を継続的に記録し、あとから
24時間・7日・30日の履歴を見返せる軽量なメニューバーアプリです。

本プロジェクトは、Codexによるノンコード開発のアプリです。利用者が
コードを直接記述せず、Codexとの対話で要件定義・実装・検証を進めます。
生成物はSwiftとSwiftUIで実装するネイティブmacOSアプリです。

## v0.1の目的

- Mac全体のメモリ統計を5秒ごとに取得する
- 物理メモリ、使用量、有線、圧縮、キャッシュ、スワップを記録する
- メモリプレッシャーを `UNKNOWN`・`NORMAL`・`WARNING`・`CRITICAL` で記録する
- 履歴をローカルSQLiteへ保存する
- 24時間・7日・30日のグラフを表示する
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
- 次工程: 工程7「履歴集約と保存期限」
- 工程表: [v0.1確定工程表](docs/Memory_Watcher_v0.1_Final_Implementation_Plan.md)
- 確定要件: [v0.1確定要件](docs/Memory_Watcher_v0.1_Requirements.md)

## 開発

```sh
swift build
swift test
scripts/build-development-app.sh
open .build/MemoryWatcher.app
scripts/run-measurement-probe.sh 121
```

外部パッケージには依存しません。Apple SDKとmacOS同梱SQLiteだけを
使用します。
