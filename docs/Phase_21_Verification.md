# 工程21 回帰監査・アプリ化 検証記録

## 工程の範囲

工程21は、ローカル表示構成を追加したv0.3候補について、実履歴の読戻し、
表示中・非表示中の軽量性、SQLite整合性、非通信境界、署名済みappとZIPを
最終確認する工程です。測定式、保持期間、gapの意味はv0.2から変更しません。

## 実履歴と表示設定の読戻し

実際に蓄積されたSQLiteを読み取り専用で開き、期間ごとの保存解像度、メモリ、
Mac全体CPU、論理CPU別CPU、代表時刻の選択結果を確認しました。

| 期間 | 保存元 | メモリ点 | 全体CPU点 | 論理CPU点 | gap | sleep | UNKNOWN | 判定 |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| 12時間 | raw | 8,601 | 8,635 | 69,080 | 39 | 0 | 0 | PASS |
| 24時間 | raw | 17,241 | 17,268 | 138,144 | 39 | 0 | 0 | PASS |
| 3日 | 1分集約 | 4,282 | 4,286 | 34,496 | 193 | 2 | 3 | PASS |

8論理CPUをすべて読戻し、各期間で3時点のメモリ・全体CPU・論理CPU選択が
一致しました。3日履歴ではsleep、UNKNOWN、gapを保持し、推測による補間を
行っていません。

compact、balanced、detailedの3プリセットは、それぞれ現在値領域の高さ
260、320、380 pointsで保存・再読込できました。最後にresetを実行し、
balancedの標準構成へ戻ることも確認しました。SQLite `integrity_check`は`ok`です。

## 表示中・非表示中の実運転

同じ工程21実装候補を、ウォームアップ後に表示30分、続けて非表示30分動かし、
5分ごとにCPU、RSS、Internet socket、記録件数を外部観測しました。

| 項目 | 表示30分 | 非表示30分 |
|---|---:|---:|
| 平均CPU使用率 | 0.542% | 0.167% |
| メモリ記録slot | 362 | 362 |
| 全体CPU記録slot | 362 | 361 |
| 説明不能なメモリgap | 0 | 0 |
| 論理CPU gap | 0 | 0 |
| 監視失敗 | 0 | 0 |
| 履歴自動再読込 | 6 | 0 |
| Internet socket | 全観測0 | 全観測0 |
| 判定 | PASS | PASS |

RSSは42,688から131,808 KiBの範囲で増減し、単調増加ではありませんでした。
毎時の保持期限整理で古いraw行が削除されても監査時間帯の記録を誤って欠落扱い
しないよう、件数は時刻範囲付きSQLで判定しています。境界を含む単体試験も
追加しました。

## 容量・非通信・回帰試験

| 項目 | 観測結果 |
|---|---|
| 実DB、WAL、SHM合計 | 30,171,608 bytes |
| DB容量上限 | 67,108,864 bytes |
| SQLite `integrity_check` | `ok` |
| 外向き通信API | 0件 |
| 通知API | 0件 |
| 全回帰テスト | 133/133 PASS |
| `swift format lint --strict` | 警告・違反0 |
| 公開境界scan | 端末固有path、認証情報、非公開ログ、内部実行手段の痕跡0 |

## app・ZIP・機種境界

| 項目 | 観測結果 |
|---|---|
| version / build | 0.3.0 / 1 |
| Apple Silicon Release build | PASS。Apple M2実機で履歴読戻しと実運転を確認 |
| Intel x86_64 Release build | PASS。buildのみで実機実行は未検証 |
| app署名 | ad-hoc署名、strict verify PASS |
| appとZIP展開後の実行ファイル | SHA-256一致 |
| 実行ファイルSHA-256 | `491f7654e489dee4051a31f28b28a1b5fff1da240a7cdb45af9023b8582fb8d0` |
| ZIP SHA-256 | `3aa646fb96cdb8a87b8d2794e6f2f21c96bea7878d404a63e64fafcd4ea8bebb` |

Developer ID署名、notarization、App Store配布、Intel実機での実運転は本工程の
対象外です。

## 工程21完了ゲート

- [x] 12時間・24時間・3日の実履歴を正しい保存元から読戻した
- [x] sleep・UNKNOWN・gapを補間せず保持した
- [x] メモリ・全体CPU・論理CPUと代表3時点を読戻した
- [x] 3プリセットの保存・復元・resetを確認した
- [x] 表示・非表示各30分の平均CPU使用率が1%未満
- [x] RSS単調増加なし、Internet socket 0、監視失敗0
- [x] DB容量上限内、SQLite整合性`ok`
- [x] 全133テスト、Release build、strict format lintがPASS
- [x] 署名済みapp、ZIP、展開後実行ファイルを読戻した
- [x] Apple Silicon実機とIntel buildの検証境界を区別した
- [x] 公開情報漏洩scanがPASS
- [ ] 工程21の非merge commitが`main`からちょうど1個
- [ ] ready Pull Request、merge commit、GitHub remote mainの読戻しが完了

技術条件はすべて`PASS`です。この記録を含む工程21差分を1個の非merge commitへ
まとめ、ready Pull Request、merge commit、GitHub remote mainの読戻しを順に
確認した時点で、工程21とMemory Watcher v0.3を完成とします。
