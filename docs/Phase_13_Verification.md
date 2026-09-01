# 工程13 CPU取得要件・品質契約 検証記録

## 工程の範囲

工程13はCPU計測の意味と品質を固定する工程です。OSからの継続取得、SQLite保存、
集約、グラフ表示は工程14以降で実装します。

## 前提条件

- [x] v0.1工程12のPull Requestがmainへマージ済み
- [x] remote mainと工程12 merge commitが一致
- [x] v0.1のメモリ記録・sleep gap・SQLiteのみ保存する境界を維持
- [x] v0.2はCPUまで。GPU、プロセス別・アプリ別解析は対象外

## 固定した契約

- [x] 目標測定周期を5秒に固定
- [x] Mac全体は `HOST_CPU_LOAD_INFO` の累積tick差分を使用
- [x] 論理CPU別は `PROCESSOR_CPU_LOAD_INFO` のindex別累積tick差分を使用
- [x] `user + system + nice` をbusy、busyとidleの合計を分母に固定
- [x] Mac全体をCPU別パーセントの単純平均で作らない
- [x] 初回、不連続、取得不能、回帰、無進行、桁あふれを理由付きUNKNOWNに固定
- [x] sleep、wake、再起動、topology変更を横切る値を生成しない
- [x] 0始まり保存indexと1始まり中立表示名の対応を固定
- [x] 物理コア、高性能・高効率コア種別を推測しない
- [x] Activity Monitorの数値・傾向・非保証境界を差異表で固定
- [x] 32論理CPUfixture、保持DB 128MiB、取得p95 10ms、最終CPU 1%の条件を固定

詳細は [CPU指標定義 v1](CPU_Metric_Definitions_v1.md) に保存します。

## 回帰試験

`CPUMetricDefinitionTests`は次を検証します。

1. 計算式versionと5秒周期
2. 初回差分のUNKNOWN
3. user・system・nice・idle差分と50%の内訳
4. 0%と100%の区別
5. 合計tick比25%と単純平均の禁止
6. カウンター回帰と無進行
7. sleep・wake・再起動・時計・topology・取得不能のUNKNOWN
8. 算術桁あふれ時にclampしないこと

## 実測結果

| 検証 | 結果 |
|---|---|
| macOS SDKのMach CPU定義をSwiftから参照 | PASS。全体・論理CPU flavor、4状態、構造体を確認 |
| `CPUMetricDefinitionTests` | 8/8 PASS |
| 全回帰テスト | 71/71 PASS |
| Releaseビルド | PASS |
| `swift format lint` | 警告・違反0 |
| 公開境界検査 | 端末固有パス、認証情報、非公開の開発調整情報0 |

## 工程13完了ゲート

- [x] `SAMPLING_INTERVAL_5_SECONDS`
- [x] `MAC_TOTAL_AND_LOGICAL_CPU_FORMULAS_FIXED`
- [x] `FIRST_DELTA_UNKNOWN`
- [x] `ACTIVITY_MONITOR_COMPARISON_BOUNDARY_FIXED`
- [x] `PERFORMANCE_EFFICIENCY_CORE_LABELS_NOT_INFERRED`
- [x] 全回帰テスト、Releaseビルド、format lintがPASS
- [x] 公開情報漏洩検査がPASS
- [ ] 工程13の非merge commitがちょうど1個
- [ ] ready Pull Requestが作成されchecksがPASS
- [ ] merge commitとGitHub remote readbackが一致

最後の3項目は、この文書を含む工程コミットの作成後にだけ観測できます。
GitHub上のPR、merge commit、remote readbackまで確認するまでは、工程13の
技術条件がPASSしていても工程14へ進みません。
