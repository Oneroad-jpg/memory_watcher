# 工程17 統合版最終監査 検証記録

## 工程の範囲

工程17は、メモリ、Mac全体CPU、論理CPU別CPUを単一ウインドウへ統合した
v0.2.1候補について、24時間実運転、Activity Monitor照合、軽量性、保存容量、
SQLite整合性、非通信境界、Apple Silicon実機とIntel向けbuildを最終確認する工程です。
GPU、アプリ別・プロセス別解析、AI、通知、外向き通信は対象外です。

## 24時間実運転

同一のv0.2.1 build 2候補を同一PID・同一実行ファイルSHAのまま24時間以上動かし、
固定済みcheckpointと比較記録を再作成せずに判定しました。

| 項目 | 観測結果 |
|---|---|
| 実運転時間 | 86,681秒。24時間条件を通過 |
| 記録sample | 17,279件 |
| 説明不能な測定欠落 | 0件 |
| 明示gap | 2件。監査境界として診断可能 |
| sleep / wake | 完了区間1件 |
| sleep区間内のsample | 0件 |
| 履歴marker読戻し | PASS |
| SQLite `integrity_check` | `ok` |
| 予期しない再起動・別候補起動 | 0件 |
| 最終判定 | `PASS` |

## Activity Monitor照合

開始後、sleep復帰後、終了前の3時点でActivity Monitorの実表示を読み、直後の
Memory Watcher実測値と時刻付きで比較しました。物理メモリ、使用済みメモリ、
確保されているメモリ、圧縮、キャッシュ、スワップの6項目を対象とし、推測値は
記録していません。

3件とも、Activity Monitor側の丸めと非同期更新、Memory Watcher側の公開VM
counterと文書化した計算式によって差を説明できました。拒否された比較と
説明不能な比較は0件で、比較条件は`PASS`です。

## 軽量性・容量・非通信

同じ候補を約6時間間隔で5回観測しました。

| 項目 | 観測結果 |
|---|---|
| 観測span | 86,708秒 |
| 平均CPU使用率 | 0.901%。目標1%未満 |
| RSS | 最大195,526,656 bytes、終了時42,958,848 bytes |
| RSS単調増加 | なし |
| Internet socket | 全観測0 |
| 外向き通信API | 0件 |
| 通知API | 0件 |
| 予測保持DB容量 | 30,386,208 bytes |
| DB容量上限 | 67,108,864 bytes |
| SQLite `integrity_check` | `ok` |
| 最終判定 | `PASS` |

## 回帰試験と候補読戻し

| 試験 | 観測結果 |
|---|---|
| 全回帰テスト | 117/117 PASS |
| `swift format lint --strict` | 警告・違反0 |
| arm64 Release build | PASS |
| Intel x86_64 Release build | PASS。buildのみで実機実行は未検証 |
| v0.2.1 build 2 app署名 | ad-hoc署名、strict verify PASS |
| appとZIP展開後の実行SHA | 一致 |
| 実行ファイルSHA-256 | `b2867dd715faaeed07f249dc37826c59a5f73d2c082458240b00e124b496cdb1` |
| ZIP SHA-256 | `2eb6f82bf86769c02bcb4f658b871da707046adc725f02e5ed7f42a041ce2d14` |
| 3日履歴UI読戻し | 4,199 memory点、4,199 total CPU点、33,592 logical CPU点 |
| 履歴読込・画面準備 | 0.100秒・0.501秒、2秒以内 |
| sleep区間読戻し | 1件、PASS |
| 公開境界scan | 端末固有path、認証情報、非公開ログ、内部実行手段の痕跡0 |

## 機種差と未検証境界

- Apple Silicon実機では24時間監査、sleep / wake、Activity Monitor照合を実施済みです。
- Intelはx86_64 Release buildまで確認し、Intel実機での実運転は未検証です。
- Activity Monitorとの完全な数値一致や同一の連続曲線は保証しません。
- Developer ID署名、notarization、App Store配布は本工程の対象外です。

## 工程17完了ゲート

- [x] 24時間実運転が`PASS`
- [x] 説明不能な測定欠落0、sleep中sample 0
- [x] sleep / wake完了区間1件以上
- [x] Activity Monitor比較3件、説明不能差0
- [x] CPU平均1%未満、RSS単調増加なし
- [x] DB容量上限内、Internet socket 0、通信・通知API 0
- [x] SQLite整合性`ok`
- [x] 全117テスト、Release build、strict format lintがPASS
- [x] 署名済み候補、ZIP、履歴UIを読戻し済み
- [x] Apple Silicon実機とIntel buildの検証境界を区別
- [x] 公開情報漏洩scanがPASS
- [ ] 工程17の非merge commitが`main`からちょうど1個
- [ ] ready Pull Request、merge commit、GitHub remote mainの読戻しが完了

技術条件はすべて`PASS`です。この記録を含む工程17差分を1個の非merge commitへ
まとめ、ready Pull Request、merge commit、GitHub remote mainの読戻しを順に
確認した時点で、工程17とMemory Watcher v0.2を完成とします。
