# 工程15 論理CPU別保存 検証記録

## 工程の範囲

工程15は、macOSが公開する論理CPU indexごとの累積tickを既存の5秒sampling
slotで取得し、区間差分、CPU数、トポロジーepoch、品質状態をローカルSQLiteへ
保存する工程です。CPU履歴画面は工程16で実装します。

## 前提条件

- [x] 工程14のPull Request、merge commit、GitHub remote mainを読戻し済み
- [x] CPU指標定義v1の取得元、差分式、UNKNOWN条件を変更していない
- [x] 既存のメモリ監視、Mac全体CPU、sleep gap、非通信境界を維持
- [x] GPU、物理コア種別の推測、プロセス別・アプリ別解析は対象外

## 実装結果

- [x] `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`から論理CPU別累積tickを取得
- [x] APIが確保したprocessor infoを取得後に`vm_deallocate`で解放
- [x] 0始まりのCPU indexを欠落・重複なく論理CPU数と一緒に保存
- [x] 起動セッションと論理CPU数からトポロジーepochを作成
- [x] 既存メモリ・全体CPUと同じ5秒slotを利用し、追加timerを作らない
- [x] 初回、sleep、wake、再起動、時計変更、トポロジー変更を理由付きUNKNOWNにする
- [x] 取得不能時は論理CPU値を生成せず、1件の`unavailable` gapとして保存
- [x] 1つのCPUでcounter回帰が起きても値を丸めず、他CPUの実測値を保持
- [x] SQLite schema v5へトポロジー、生データ、gap、1分・5分集約を追加
- [x] v2・v3・v4データベースからv5へ移行して既存履歴を保持
- [x] 生データ24時間、1分・5分集約3日の保持境界を実装
- [x] 集約をトポロジーepochとCPU indexごとに分離
- [x] 集約値は百分率の平均ではなくtick合計から再計算
- [x] 集約成功前の失敗では論理CPU・全体CPU・メモリsourceをrollbackで保持

## 全体CPUとの対応

全体CPUと論理CPU別の値は同じ5秒sampling slot内で取得し、同じtick差分式と
品質語彙を使います。ただしOS APIの取得は同時刻の原子的snapshotではないため、
全体CPU値と論理CPU値の合計が各slotで完全一致することは保証しません。
取得時刻、区間、UNKNOWN境界を保存し、差を0埋めや補正で隠しません。

論理CPU indexはOSが返した配列上の識別子です。物理コア番号や
高性能・高効率コア名とは断定しません。

## 決定的試験

| 試験 | 観測結果 |
|---|---|
| live processor info取得 | PASS。実機で全論理CPU indexを取得し、初回UNKNOWNを検証 |
| CPU数fixture | PASS。1・8・16・32論理CPUでindexの欠落・重複0 |
| 再起動・トポロジー変更 | PASS。別epochと明示UNKNOWN境界を生成 |
| 取得不能 | PASS。CPU値を生成せず`unavailable` gapを保存 |
| counter回帰 | PASS。対象CPUだけUNKNOWN、他CPUは実測を保持 |
| SQLite保存・読戻し | PASS。batch round trip、重複batch rollback、epoch衝突拒否 |
| schema migration | PASS。v4からv5へ移行しメモリ・全体CPU履歴を保持 |
| 1分・5分集約 | PASS。epoch・CPU index別にtick合計から再計算 |
| transaction rollback | PASS。集約失敗時に全sourceと生データを保持 |
| 監視engine | PASS。同一slot、gap保存、sleep・wake resetを確認 |
| 32 CPU容量 | PASS。実測fixtureは160 bytes/row以下、最大予測123,404,288 bytes |
| 全回帰テスト | 98/98 PASS |
| Releaseビルド | PASS |
| `swift format lint --strict` | 警告・違反0 |
| 公開境界検査 | 端末固有パス、認証情報、非公開ログ、通信・通知API追加0 |

32論理CPUでの保持行数は、生データ552,960行、1分集約138,240行、
5分集約27,648行です。8 MiBの固定領域を含む最大予測は
123,404,288 bytesで、工程13の128 MiB上限以下です。33論理CPU以上は切り捨てず
取得・保存しますが、容量条件は未検証境界として扱います。

## incident読戻し

SQLiteのトポロジー照合で、例外を返す日時変換を`try`なしで比較式から
呼び出したため、初回Debugビルドが停止しました。期待値を`try`付きで事前計算する
限定修正後、Debugビルド、論理CPU関連14テスト、全98テスト、Releaseビルドを
再実行し、同じincidentが再現しないことを確認しました。DB書込み前の
コンパイル停止だったため、保存済みデータへの変更や破損はありません。

## 工程15完了ゲート

- [x] `CPU_INDEX_AND_CORE_COUNT_SAVED`
- [x] `PER_LOGICAL_CPU_SAMPLE_EVERY_5_SECONDS`
- [x] `REBOOT_AND_TOPOLOGY_CHANGE_HANDLED`
- [x] `NO_FABRICATED_SAMPLE_FOR_UNAVAILABLE_CPU`
- [x] `PER_LOGICAL_CPU_AGGREGATION_PASS`
- [x] 1・8・16・32 CPU fixtureとlive API試験がPASS
- [x] SQLite v5 migration、保持期限、rollback、integrity試験がPASS
- [x] 32 CPU容量予測が128 MiB以下
- [x] 全98テスト、Releaseビルド、strict format lint、公開境界検査がPASS
- [ ] 工程15の非merge commitがちょうど1個
- [ ] ready Pull Requestが作成される
- [ ] merge commitとGitHub remote readbackが一致

最後の3項目は、この記録を含む工程コミットの作成後にだけ観測します。
それまでは工程15の技術条件PASSと工程完了を区別し、工程16へ進みません。
