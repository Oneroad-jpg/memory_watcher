# 工程20 アプリ内表示構成エディタ 検証記録

## 工程の範囲

工程20は同じMemory Watcherウインドウからローカル表示構成sheetを開き、
表示密度、セクション順、任意セクションの表示状態を変更・保存する工程です。
設定はUserDefaultsだけへ保存し、SQLite、監視エンジン、履歴DB接続、測定周期、
保持期間、gapの意味は変更しません。

## 実装した操作

- [x] 現在値領域の「表示設定」ボタンとCommand-commaで同じウインドウにsheetを表示
- [x] compact・balanced・detailedをsegmented pickerで選択
- [x] 各セクションを上・下ボタンで並べ替え
- [x] 論理CPU別履歴と選択時刻詳細をcheckboxで表示・非表示
- [x] メモリ履歴とMac全体CPUを常時表示として明示
- [x] 「標準に戻す」でbalanced・標準順・全表示へreset
- [x] Button、Picker、Toggleと明示的なaccessibility label・hint・identifierを使用

## 保存と回復

schema付き`DashboardLayoutConfiguration`を
`dashboard.layout.configuration.v1`へJSONとして保存します。

| 条件 | 観測結果 |
|---|---|
| 保存値なし | balanced・標準順・全表示を返し、不要な保存値を作らない |
| 正常な保存値 | 新しいstore／表示モデルから同じ設定を復元 |
| decode不能 | balanced・標準順・全表示へ回復し、修復値を保存 |
| 未知schema | 推測せずbalanced・標準順・全表示へ回復 |
| reset | balanced・標準順・全表示を即時反映して保存 |

保存と回復の決定的試験は5/5 PASSです。

## 実アプリUI検証

一時SQLiteと一時UserDefaults suiteを使って実際の`MemoryWatcher`実行ファイルを
起動し、設定sheetの表示、compact選択、順序変更、論理CPU履歴の非表示、保存、
新しい表示モデルからの復元、reset、sheet終了を連続して検証しました。

| 項目 | 観測結果 |
|---|---|
| sheet表示・終了 | PASS |
| 設定の即時反映 | PASS |
| 現在値・履歴root再描画 | 各3回、PASS |
| 新しい表示モデルからの復元 | PASS |
| reset保存 | PASS |
| 監視エンジンidentity | 変更なし |
| DB接続identity | 変更なし |
| 設定変更による履歴再読込 | 0回 |
| SQLite `integrity_check` | `ok` |
| 最終判定 | `PASS` |

初回試験では表示設定revisionが既存の再描画probe入力に含まれず、実表示が
反映済みでも診断カウンターだけが更新されないincidentを検出しました。
probeへ表示設定revisionを追加する限定修正後、同一試験はPASSしました。
既存の描画分離試験も、現在値120回更新に対して履歴root更新0・履歴再読込0で
PASSしています。

## 回帰試験

| 試験 | 観測結果 |
|---|---|
| 表示設定の対象試験 | 13/13 PASS |
| 全回帰テスト | 130/130 PASS |
| 既存描画分離fixture | PASS |
| 工程19の6画面fixture | 6/6 PASS、最大1.494秒 |
| `swift format lint --strict` | 警告・違反0 |
| arm64 Release build | PASS |
| Intel x86_64 Release build | PASS。buildのみで実機実行は未検証 |
| 公開境界scan | 端末固有path、認証情報、非公開ログ、内部実行手段の痕跡0 |
| 通信・通知API scan | 新規0件 |

## 工程20完了ゲート

- [x] 同じウインドウから設定sheetを開閉できる
- [x] プリセット、順序、任意表示、resetを操作できる
- [x] マウス・キーボード操作可能な標準SwiftUI controlを使用
- [x] VoiceOver用の設定名、操作名、現在状態を保持
- [x] 設定変更を両ペインへ即時反映
- [x] 設定変更で監視エンジンとDB接続を再生成しない
- [x] 設定変更だけでは履歴を再読込しない
- [x] 再起動相当の新しい表示モデルで保存設定を復元
- [x] 壊れた保存値と未知schemaをbalancedへ回復
- [x] resetで標準順・全表示へ戻る
- [x] 全130テスト、6画面fixture、Release build、strict lintがPASS
- [x] 通信・通知APIと公開情報漏洩0
- [ ] 工程20の非merge commitが`main`からちょうど1個
- [ ] ready Pull Request、merge commit、GitHub remote main読戻しが完了

最後の2項目は工程commit作成後にだけ観測できます。GitHubでの保存と読戻しが
完了するまでは工程21へ進みません。
