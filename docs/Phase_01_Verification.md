# Phase 01 Verification — Project Foundation

## 完了条件

- [x] クリーンな状態からSwift Packageをビルドできる
- [x] 単体テストを実行できる
- [x] SwiftUIとSwift Chartsを使用する空のmacOSアプリが起動する
- [x] macOS同梱SQLiteへリンクできる
- [x] Memory Watcher専用リポジトリとして分離されている
- [x] 公開境界検査を通過する

## 検証環境

- macOS 26.6
- Xcode 26.6
- Apple Swift 6.3.3
- SQLite 3.51.0

## 実行する検証

```sh
swift package dump-package
swift package clean
swift build
swift test
scripts/build-development-app.sh
.build/MemoryWatcher.app/Contents/MacOS/MemoryWatcher --smoke-test
```

## 実測結果

| 検証 | 結果 |
|---|---|
| Package定義 | PASS。macOS 14.0、外部依存0件 |
| クリーンビルド | PASS |
| 単体テスト | 3件実行、失敗0件 |
| SQLiteリンク | PASS。実行時バージョン番号が0より大きい |
| Info.plist | `plutil`検査PASS |
| 開発用署名 | `codesign --verify --strict` PASS |
| アプリ起動 | PASS。bundle ID一致、ウインドウ1件、可視状態true |

起動読戻し:

```json
{"bundle_identifier":"com.oneroad.memorywatcher","status":"PASS","visible":true,"window_count":1}
```

通常起動は次で行います。

```sh
open .build/MemoryWatcher.app
```
