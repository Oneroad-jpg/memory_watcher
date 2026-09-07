# Memory Watcher v0.3.3

Memory Watcher v0.3.3は、Mac全体のメモリとCPUを5秒ごとにローカル記録し、
12時間・24時間・3日の履歴を確認できるmacOSメニューバーアプリです。

## この版の主な内容

- Developer ID Applicationで署名
- Hardened Runtimeと安全なタイムスタンプを有効化
- Appleの公証を通過し、公証チケットをアプリへ添付
- Gatekeeper評価を通過
- 起動中のアプリを上書きしない安全な更新経路
- 失敗時に旧版を戻せる更新時バックアップ

メモリ・CPUの測定式、5秒間隔、SQLite schema、保持期間、画面構成、
非通信・非通知の境界はv0.3.2から変更していません。

## 対応環境

- macOS 14以降
- Apple Silicon（arm64）

配布ZIPはApple Silicon専用です。Intel向けのソースビルドは確認していますが、
Intel実機での動作は未検証です。Universal Binaryではありません。

## インストール

1. Release Assetsから `MemoryWatcher-0.3.3.zip` をダウンロードする
2. ZIPを展開する
3. `MemoryWatcher-0.3.3.app` をApplicationsフォルダへ移動する
4. アプリを開き、メニューバーのアイコンから「履歴を開く」を選ぶ

更新時は、起動中のMemory Watcherを終了してからアプリを置き換えてください。
既存のSQLite履歴と表示設定は利用者のライブラリ内に残ります。

## SHA-256

```text
861079b48b6d7c2ba6d5424683917b375044824d3f5d88a22acc7aeae692844c
```

照合例:

```sh
shasum -a 256 MemoryWatcher-0.3.3.zip
```

## 検証範囲

- Developer ID署名、Hardened Runtime、安全なタイムスタンプ
- Apple公証 `Accepted`、公証issueなし
- `stapler validate`、`spctl --assess`、strict codesign
- ZIP展開後の再検証
- M2・16 GB MacへのインストールとSQLite実記録読戻し
- SQLite `integrity_check=ok`
- 全134テスト

長時間実機確認はM2 Macが中心です。ほかのApple Silicon機種とIntel Macで
同じ範囲の実機監査を終えたとは扱いません。

## プライバシーと対象外

測定履歴はMac内のSQLiteにだけ保存します。外向き通信、通知、クラウド同期、
プロセス別・アプリ別解析、GPU記録、AI診断、自動更新は行いません。

詳細は[README](../README.md)と
[工程24署名・公証検証](Phase_24_Verification.md)を参照してください。
