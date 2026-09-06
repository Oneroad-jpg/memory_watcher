# 工程23 選択時刻詳細の表形式化 検証記録

## 工程の範囲

工程23は、履歴末尾の選択時刻詳細を、小さな数値カードから文字の大きい表へ
変更する工程です。メモリ・CPUの測定式、5秒間隔、SQLite schema、
12時間・24時間・3日の保持と集約、sleep・UNKNOWN・gap、通信・通知境界、
表示設定による詳細欄の表示・非表示は変更していません。

## 表示内容

- 見出しを「選択時刻（UTC）」へ変更し、日時を等幅数字の大きな文字で表示する
- Pressureを同じ見出し行のバッジとして表示する
- メモリとMac全体CPUを「項目・値・測定区間」の3列表で表示する
- user・system・nice・idleを2列表で表示する
- 論理CPUを「CPU・使用率」の2組4列表で表示する
- 奇数個の論理CPUでは最終組の空き側を`—`とし、実測値を欠落させない
- 未測定値は推測・平均化・補間せず「この時刻は未測定」と表示する

数値本文はbody相当、選択日時はtitle3相当です。各表には個別の
accessibility identifierを持たせました。

## 選択時刻の安定化

複数のSwift Chartsが同じ選択状態を共有する標準幅では、初期配置時にデータの
ない右端時刻が書き戻される場合がありました。Chart由来の時刻は、メモリと
Mac全体CPUの両方が保存されている場合だけ採用します。期間変更やウインドウを
閉じたときの明示的な選択解除、sleep・UNKNOWN・gapを空白にする既存動作は
維持しています。

## Release UI検証

| 条件 | 配置 | 論理CPU | 選択詳細 | 画面準備 | 判定 |
|---|---|---:|---|---:|---|
| 1,080×900、24時間、dark、balanced | columns | 8 | メモリ・CPU全体・8CPU一致 | 1.992秒 | PASS |
| 780×700、12時間、light、balanced | stacked | 7 | メモリ・CPU全体・7CPU一致 | 0.704秒 | PASS |
| 1,080×900、3日、dark、balanced | columns | 8 | 1分集約・8CPU一致 | 0.717秒 | PASS |

標準幅と最小幅で文字の重なり・切断は検出されず、奇数CPUの末尾を含む全値へ
スクロールで到達できます。24時間表示は既存の2秒未満ゲートを満たしました。

## 回帰・成果物

| 項目 | 観測結果 |
|---|---|
| 全回帰テスト | 134/134 PASS |
| `swift format lint --strict` | 警告・違反0 |
| Apple Silicon Release build | PASS |
| Intel x86_64 Release build | PASS。buildのみで実機実行は未検証 |
| version / build | 0.3.2 / 1 |
| app署名 | ad-hoc署名、strict verify PASS |
| appとZIP展開後の実行ファイル | byte一致 |
| 実行ファイルSHA-256 | `05e6003dee44a48f68c73687583b7bd30118fc164b08392afe68013218637ed4` |
| ZIP SHA-256 | `ddba75a78dd548a586fa7ac042f09ee6dfb5e549fd980fcfaec6e4bc57906f7c` |
| SQLite `integrity_check` | `ok` |
| 外向き通信API / 通知API | 0件 / 0件 |
| 公開境界scan | 端末固有path、認証情報、非公開ログ、内部実行手段の痕跡0 |

Developer ID署名、notarization、App Store配布、Intel実機での実運転は本工程の
対象外です。

## 工程23完了ゲート

- [x] 選択時刻とPressureを読みやすい見出しへ変更した
- [x] メモリとMac全体CPUを3列表にした
- [x] CPU内訳と全論理CPUを表形式にした
- [x] 7CPU・8CPUで欠落と範囲外参照がない
- [x] 12時間・24時間・3日で選択詳細が一致した
- [x] sleep・UNKNOWN・gap、SQLite schema、測定式、保持期間を変更していない
- [x] 全134テスト、Release build、Intel build、strict format lintがPASS
- [x] 署名済みapp、ZIP、展開後実行ファイルを読戻した
- [x] SQLite整合性、非通信・非通知、公開情報漏洩scanがPASS
- [ ] 工程23の非merge commitが`main`からちょうど1個
- [ ] ready Pull Request、merge commit、GitHub remote mainの読戻しが完了
- [ ] v0.3.2をインストールし、実画面と新規記録を確認した

技術条件はすべて`PASS`です。この記録を含む工程23差分を1個の非merge commitへ
まとめ、Pull Requestとremote readbackを完了した後にv0.3.2を導入します。
