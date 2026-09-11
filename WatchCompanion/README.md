# Memory Watch Apple Watch companion基盤

このディレクトリには、読取専用Apple Watch companionのsource-build基盤を格納します。
現行のv0.3.3 releaseには含まれません。

現在の状態：

- watchOS app targetと読取専用UIのsourceは存在します。
- バージョン付きの共有snapshot契約は存在します。
- 現在の解析器は決定的です。
- `PL2`の認証済みMac-to-Watch転送は定義済みですが未実装なので、Macのlive dataは
  まだ転送しません。
- 使用しないPhaseは`UNDEFINED`のまま保持し、責務を割り当てません。

Xcode projectの生成・確認手順：

```sh
cd WatchCompanion
xcodegen generate
xcodebuild -project MemoryWatcherWatch.xcodeproj -scheme MemoryWatcherWatch \
  -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

build成功を、実機インストールやMac-to-Watchデータ転送の完了として扱わないでください。
それぞれ別の観測済み受入証拠が必要です。
