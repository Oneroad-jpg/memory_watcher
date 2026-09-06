# 工程22 上部余白削減・CPU一覧 検証記録

## 工程の範囲

工程22は、現在値領域の下に残っていた固定余白を履歴領域へ戻し、標準幅で
8論理CPUの履歴を2列4行に一覧表示する工程です。メモリ・CPUの取得式、
5秒間隔、SQLite schema、12時間・24時間・3日の保持と集約、sleep・UNKNOWN・
gap、通信・通知境界は変更していません。

## 実画面の配置

インストール済みv0.3.1を終了・再起動し、標準1,080×900 pointsのウインドウを
実際に開いて確認しました。実コンテンツ高868 pointsに対するbalancedの配置は
次のとおりです。

| 項目 | v0.3 | v0.3.1 | 差 |
|---|---:|---:|---:|
| 現在値領域 | 320 points | 138.88 points | -181.12 points |
| 履歴領域 | 548 points | 729.12 points | +181.12 points |

ログイン時起動の行の直下から履歴カードが始まり、従来の固定空間は残りません。
同じ実画面でCPU 1〜8の履歴カードを2列4行ですべて表示できました。現在値側も
CPU 1〜8を1行で保持し、メモリ、スワップ、Pressure、Mac全体CPUの履歴を
欠落させていません。

## 適応レイアウトと実履歴

標準幅のfixtureでは2列配置、780 points幅・32論理CPUのfixtureでは既存の
stacked配置へ戻ることを確認しました。CPU系列は切り捨てず、狭幅や多CPUでは
スクロールで到達します。

| 条件 | 配置 | CPU | 履歴点 | 読込 | 判定 |
|---|---|---:|---:|---:|---|
| 1,080×900、24時間、balanced | columns・2列 | 8 | メモリ1,439、全体CPU1,439、論理CPU11,512 | 1.993秒 | PASS |
| 780×700、12時間、balanced | stacked・自動列 | 32 | 論理CPU23,008 | 0.821秒 | PASS |

実SQLiteの読戻しでも、12時間はメモリ8,585点・全体CPU8,618点・論理CPU
68,944点、24時間は17,225点・17,252点・138,016点、3日は4,235点・
4,239点・34,104点を取得しました。3日表示ではsleep 2件、UNKNOWN 4件、
gap 194件を保持し、補間していません。各期間の代表3時点の選択も一致しました。

## 回帰・成果物・導入

| 項目 | 観測結果 |
|---|---|
| 全回帰テスト | 134/134 PASS |
| `swift format lint --strict` | 警告・違反0 |
| Apple Silicon Release build | PASS |
| Intel x86_64 Release build | PASS。buildのみで実機実行は未検証 |
| version / build | 0.3.1 / 1 |
| app署名 | ad-hoc署名、strict verify PASS |
| appとZIP展開後の実行ファイル | byte一致 |
| 実行ファイルSHA-256 | `6af0d01cbfcd80ccde27d7b6ff438c43c5d4c6df97b7452973c26e6eb6702408` |
| ZIP SHA-256 | `0acd67f911a69c107d792f902f45b2d6827427c68e26e0d264a5e81df66ad35a` |
| SQLite `integrity_check` | `ok` |
| 外向き通信API / 通知API | 0件 / 0件 |
| 公開境界scan | 端末固有path、認証情報、非公開ログ、内部実行手段の痕跡0 |

インストール済み実行ファイルは候補appとSHA-256が一致しました。再起動後の
6秒観測で、メモリ行は17,241から17,242、Mac全体CPU行は17,309から
17,310、論理CPU行は138,472から138,480へ増え、5秒測定と8CPUの保存が
実際に継続していることを確認しました。

Developer ID署名、notarization、App Store配布、Intel実機での実運転は本工程の
対象外です。

## 工程22完了ゲート

- [x] ログイン時起動行と履歴表示の固定余白を削減した
- [x] 標準ウインドウで現在値138.88 points、履歴729.12 pointsを確認した
- [x] CPU 1〜8を2列4行ですべて実画面表示した
- [x] 狭幅・32CPUでstacked配置と全系列保持を確認した
- [x] 12時間・24時間・3日とsleep・UNKNOWN・gapを退行させていない
- [x] SQLite schema、測定式、保持期間、通信・通知境界を変更していない
- [x] 全134テスト、Release build、Intel build、strict format lintがPASS
- [x] 署名済みapp、ZIP、展開後実行ファイルを読戻した
- [x] v0.3.1をインストールし、実画面と新規記録を確認した
- [x] SQLite整合性と公開情報漏洩scanがPASS
- [ ] 工程22の非merge commitが`main`からちょうど1個
- [ ] ready Pull Request、merge commit、GitHub remote mainの読戻しが完了

技術条件はすべて`PASS`です。この記録を含む工程22差分を1個の非merge commitへ
まとめ、ready Pull Request、merge commit、GitHub remote mainの読戻しを順に
確認した時点で、工程22とMemory Watcher v0.3.1を完成とします。
