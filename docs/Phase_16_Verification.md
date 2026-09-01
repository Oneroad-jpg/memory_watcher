# 工程16 CPU履歴グラフ 検証記録

## 工程の範囲

工程16は、工程14・15でSQLiteへ保存したMac全体CPUと論理CPU別の履歴を、
既存のメモリ履歴と同じ12時間・24時間・3日の期間で表示する工程です。
GPU、プロセス別・アプリ別CPU解析、物理コア種別の推測は含みません。

## 前提条件

- [x] 工程15のPull Request #16、merge commit、GitHub remote mainを読戻し済み
- [x] CPU指標定義v1のtick差分式とUNKNOWN条件を変更していない
- [x] 既存のメモリ履歴、sleep gap、ローカルSQLite、非通信境界を維持
- [x] 画面上の論理CPU名はOSのindexに対応する中立な名称だけを使用

## 実装結果

- [x] Mac全体CPU使用率を0〜100%の履歴グラフとして表示
- [x] 論理CPU indexごとの使用率を0〜100%の履歴グラフとして表示
- [x] user、system、nice、idleと全体使用率を選択時刻の詳細として表示
- [x] 12時間・24時間は5秒の生データを使用
- [x] 3日は1分集約を使用
- [x] メモリ履歴とCPU履歴で期間選択と選択時刻を共有
- [x] sleep、UNKNOWN、再起動、取得不能、長い欠落を別の連続区間へ分割
- [x] トポロジーepochが異なる論理CPUを同じ線へ接続しない
- [x] 3日分のUNKNOWN境界を保持し、集約表示でも欠落を補間しない
- [x] 表示用downsamplingでも連続区間の両端を保持
- [x] 履歴ウインドウ表示中だけ5分間隔の自動再読出し対象にCPUを追加

## 表示データの対応

| 表示期間 | CPU保存層 | 代表時刻 | 表示上の扱い |
|---|---|---|---|
| 12時間 | 5秒生データ | 測定区間終了時刻 | 実測値。欠落は空白 |
| 24時間 | 5秒生データ | 測定区間終了時刻 | 実測値。欠落は空白 |
| 3日 | 1分集約 | bucket開始時刻 | tick合計から再計算。欠落は空白 |

全体CPUと論理CPU別の百分率は、保存済みtickから同じ計算式で再計算します。
3日表示も百分率の単純平均ではありません。画面の「CPU 1」は保存された
CPU index 0を1始まりで表示した名称で、物理コア番号や高性能・高効率コアを
意味しません。

## 決定的試験

| 試験 | 観測結果 |
|---|---|
| 期間と保存層 | PASS。12時間・24時間はraw、3日はoneMinute |
| tick構成 | PASS。user・system・nice・idleと使用率が保存値に一致 |
| UNKNOWN・sleep・取得不能 | PASS。線を補間せず別segmentへ分割 |
| topology変更 | PASS。異なるepochを接続しない |
| 3日UNKNOWN保持 | PASS。境界markerを集約期間まで保持 |
| 32論理CPU・3日読出し | PASS。138,240論理CPU点のload計測が2秒未満 |
| 実アプリUI smoke | PASS。3日画面を0.859秒で準備 |
| UI smoke履歴件数 | PASS。メモリ4,199、全体CPU4,199、論理CPU33,592点 |
| UI smoke sleep | PASS。1 sleep区間を保持 |
| 全回帰テスト | 104/104 PASS |
| Debug・Releaseビルド | PASS |
| `swift format lint --strict` | 警告・違反0 |
| 公開境界検査 | 端末固有パス、認証情報、非公開ログ、通信・通知API追加0 |

## incident読戻し

初回Debugビルドでは、App側のUI smoke fixtureがCore内部専用の
`CPUCounterDelta`初期化子を直接呼び出して停止しました。公開APIを広げず、
本番と同じ`CPUUtilizationCalculator`から固定counterのdeltaを生成する限定修正を
行いました。修正後にDebugビルド、CPU履歴6テスト、全104テスト、実アプリUI
smoke、Releaseビルドを再実行し、同じincidentが再現しないことを確認しました。

## 工程16完了ゲート

- [x] `TOTAL_AND_LOGICAL_CPU_GRAPHS_AVAILABLE`
- [x] `RANGES_12_HOURS_24_HOURS_3_DAYS`
- [x] `SLEEP_AND_UNKNOWN_GAPS_UNFILLED`
- [x] `THREE_DAY_VIEW_WITHIN_TWO_SECONDS`
- [x] `EXISTING_MEMORY_GRAPHS_REGRESSION_NONE`
- [x] 0〜100%の定義、凡例、選択時刻の値を表示
- [x] SQLiteの保存値と画面モデルを決定的試験で照合
- [x] 1・8・16・32論理CPUとトポロジー差を検証
- [x] 全104テスト、実アプリUI smoke、ReleaseビルドがPASS
- [x] strict format lint、公開境界検査がPASS

この記録を含む工程16変更は、1個の非merge commit、ready Pull Request、
merge commit、GitHub remote mainの読戻しを順に完了した時点で工程完了とします。
