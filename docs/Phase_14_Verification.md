# 工程14 Mac全体CPU保存 検証記録

## 工程の範囲

工程14はMac全体のCPU累積tickを5秒周期で取得し、区間差分と品質状態を
ローカルSQLiteへ保存し、1分・5分集約と保持期限を実装する工程です。
論理CPU別保存は工程15、CPU履歴画面は工程16で実装します。

## 前提条件

- [x] 工程13のPull Requestとmerge commitをGitHub remote mainから読戻し済み
- [x] CPU指標定義v1の取得元、差分式、UNKNOWN条件を変更していない
- [x] 既存のメモリ監視、SQLite、sleep gap、非通信境界を維持
- [x] GPU、プロセス別・アプリ別CPU解析は対象外

## 実装結果

- [x] `host_statistics(HOST_CPU_LOAD_INFO)`からMac全体の累積tickを取得
- [x] 既存メモリ監視と同じ5秒のsampling slotでCPUを取得し、追加timerを作らない
- [x] user、system、niceをbusyとして累積tick差分から0〜100%を計算
- [x] 初回、取得不能、counter回帰、無進行、桁あふれを理由付きUNKNOWNとして保存
- [x] sleep、wake、再起動、時計変更、範囲外区間を横切る実測値を作らない
- [x] メモリ取得失敗時にもCPU取得・保存を独立して継続
- [x] SQLite schema v4へCPU生データ、1分集約、5分集約の3表を追加
- [x] v2・v3データベースからv4へ移行して既存メモリ履歴を保持
- [x] 生データ24時間、1分・5分集約3日の保持境界を実装
- [x] UNKNOWNは集約から除外し、欠測値を0%として生成しない
- [x] 集約値は百分率の平均ではなくtick合計から再計算
- [x] 集約成功前の失敗ではCPU・メモリ双方のsourceをtransaction rollbackで保持

## 決定的試験

| 試験 | 観測結果 |
|---|---|
| live `HOST_CPU_LOAD_INFO`取得 | PASS。実機で初回観測を取得し、`firstDeltaUnknown`として検証 |
| 5秒差分 | PASS。busy 50、idle 50を50%として保存可能 |
| UNKNOWN境界 | PASS。初回、wake、時計変更、範囲外、取得不能を実測値にしない |
| SQLite保存・読戻し | PASS。measuredとUNKNOWNのround trip、重複batch rollback |
| schema migration | PASS。v2・v3からv4へ移行し既存メモリ履歴を保持 |
| 1分・5分集約 | PASS。tick合計100/300を33.333333%として再計算 |
| 3日fixture | PASS。CPU生データ24時間、集約3日の境界とSQLite整合性を確認 |
| 監視engine | PASS。同一slot、メモリ失敗時の独立保存、wake UNKNOWNを確認 |
| 全回帰テスト | 84/84 PASS |
| Releaseビルド | PASS |
| `swift format lint --strict` | 警告・違反0 |
| 公開境界検査 | 端末固有パス、認証情報、非公開ログ、通信・通知API追加0 |

## incident読戻し

1. Swiftへ公開されない`HOST_CPU_LOAD_INFO_COUNT`マクロ参照を、Mach構造体と
   `integer_t`の型サイズ比から算出する実装へ限定修正し、debug・Release buildを
   読戻しました。
2. テスト補助関数のoptionalクロージャ型推論でSwiftコンパイラが診断生成に
   失敗したため、明示した`@Sendable`クロージャ変数へ分離しました。
3. 修正後に全84テスト、Releaseビルド、strict format lintを再実行し、
   同じincidentが再現しないことを確認しました。

## 工程14完了ゲート

- [x] `TOTAL_CPU_SAMPLE_EVERY_5_SECONDS`
- [x] `SQLITE_SCHEMA_MIGRATION_AND_READBACK_PASS`
- [x] `ONE_MINUTE_AND_FIVE_MINUTE_AGGREGATION_PASS`
- [x] `SQLITE_INTEGRITY_OK`
- [x] `SLEEP_AND_UNKNOWN_GAPS_NOT_FABRICATED`
- [x] 3日fixtureと全回帰テストがPASS
- [x] Releaseビルド、strict format lint、公開境界検査がPASS
- [ ] 工程14の非merge commitがちょうど1個
- [ ] ready Pull Requestが作成される
- [ ] merge commitとGitHub remote readbackが一致

最後の3項目は、この記録を含む工程コミットの作成後にだけ観測します。
それまでは工程14の技術条件PASSと工程完了を区別し、工程15へ進みません。
