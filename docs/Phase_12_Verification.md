# 工程12 アプリ化・最終読戻し検証記録

## 実装範囲

- release構成からバージョン付き `.app` とZIPアーカイブを生成する
- Info.plistへ製品ID、バージョン、build番号、最小macOSを固定する
- 署名、plist、アーカイブ、実行ファイルSHA-256を生成直後に検証する
- 既存の異なるアプリを上書きしないfail-closedインストーラを用意する
- macOSの標準Applicationsフォルダへインストールした実体を起動する
- 既存SQLiteへの新規測定、履歴読込、ログイン時起動を検証する

生成物はGit管理外のbuild領域に置き、公開Gitリポジトリへバイナリや
端末固有ログを保存しません。

## 生成物

| 項目 | 読戻し結果 |
|---|---|
| 製品バージョン | `0.1.0` |
| build番号 | `1` |
| bundle identifier | `com.oneroad.memorywatcher` |
| 最小macOS | `14.0` |
| 実行形式 | arm64 Mach-O |
| 実行ファイルSHA-256 | `9778013d2f5dd4dbacc88a617cb6c7892dae81530594bfa85952c0e8feb6ed6c` |
| ZIP SHA-256 | `eb702f14265dfabff90684f7f80d9f3c9059a8246da28d8d14de175ce54d1096` |
| ZIP整合性 | PASS |

## 署名境界

このMacにはDeveloper ID Application証明書がないため、v0.1.0はhardened
runtime付きのad-hoc署名で生成しました。生成直後とインストール後の両方で
厳格なコード署名検査に合格しています。

これはローカル実行用の署名検証です。Developer ID署名、Apple notarization、
App Store配布、別のMacでのGatekeeper通過を証明するものではありません。

## インストール済み実体の読戻し

- 標準Applicationsフォルダへインストール
- 生成物とインストール済み実行ファイルのSHA-256が一致
- Info.plistと署名資源が生成物と一致
- インストール済み実体の署名、designated requirement、plist lintがPASS
- 実行中プロセスがインストール済みアプリ実体であることを確認
- 既存SQLiteを失わず、起動直後に新しい5秒測定を4件以上追記
- 追記後のSQLite `integrity_check`は `ok`
- ログイン時起動を登録後に解除し、元の未登録状態へ復元してPASS

## 履歴読戻し

インストール済み実体の履歴UI smoke testでは、3日履歴を1分集約から
4,199点読み込み、読込0.003秒未満、画面準備0.253秒未満、sleep区間1件、
ウインドウ表示を確認しました。

実SQLiteへ追記した最新測定を通常の履歴ウインドウで選択できることは、
最終UI読戻しで確認しました。インストール済み実体の通常画面は監視状態
`RUNNING`、24時間表示、読込0.049秒を示し、選択した実測点は次の値でした。

| 項目 | 履歴画面 | 同時刻のSQLite行 |
|---|---:|---:|
| 使用量（推定） | 13.42 GB | 13.42 GB |
| その他使用量 | 4.09 GB | 4.09 GB |
| 有線 | 3.04 GB | 3.04 GB |
| 圧縮 | 6.30 GB | 6.30 GB |
| キャッシュ（推定） | 3.24 GB | 3.24 GB |
| スワップ | 2.04 GB | 2.04 GB |

画面の選択時刻とSQLiteの時刻付き実測行が秒単位で一致し、読戻し後の
SQLite `integrity_check`も `ok`でした。

## 判定

生成、署名、アーカイブ、インストール、実記録、SQLite整合性、ログイン時起動、
署名済み履歴UI smoke test、通常の履歴ウインドウによる実データ読戻しを
確認しました。工程12とv0.1最終完成ゲートは `PASS` です。
