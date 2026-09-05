# 工程19 適応レイアウトとプリセット表示 検証記録

## 工程の範囲

工程19は工程18で固定した表示設定契約を実際の単一ウインドウへ適用し、
ウインドウ幅、論理CPU数、外観、プリセットが異なる場合でも一覧性を保つ工程です。
設定を変更・保存する画面は工程20、実履歴による最終回帰監査とアプリ化は工程21で
行います。

## 実装した適応表示

- [x] 現在値領域の高さを各プリセットの比率・最小値・最大値から決定
- [x] 現在値領域をスクロール可能にし、多数の論理CPUを狭い高さでも確認可能にした
- [x] 余白、セクション間隔、カード余白、各グラフ高さへプリセット値を適用
- [x] 論理CPUの現在値と履歴の最小カード幅へプリセット値を適用
- [x] 狭い画面ではstacked、広い画面ではcolumnsへ自動切替
- [x] 標準順では一覧性を優先したcolumns配置を維持
- [x] 変更された順序では全表示項目を指定順のstacked配置で描画
- [x] 論理CPU別履歴と選択時刻詳細の表示・非表示を設定から反映
- [x] メモリ履歴とMac全体CPUは常に表示

## 実アプリ画面fixture

一時SQLiteへ決定的なメモリ・Mac全体CPU・論理CPU履歴を生成し、実際の
`MemoryWatcher`実行ファイルを起動して確認しました。各行でウインドウは1枚、
期間の保存解像度、時刻選択、論理CPU数、設定値の適用、2秒以内の初期表示を
同時に検証しています。

| 期間 | 論理CPU | 要求画面 | 外観 | preset | 配置 | 初期表示 | 結果 |
|---|---:|---:|---|---|---|---:|---|
| 12時間 | 1 | 780×700 | light | compact | stacked | 0.607秒 | PASS |
| 24時間 | 8 | 780×900 | dark | balanced | stacked | 1.250秒 | PASS |
| 12時間 | 16 | 1080×900 | dark | compact | columns | 0.826秒 | PASS |
| 3日 | 32 | 1080×900 | light | detailed | columns | 1.396秒 | PASS |
| 24時間 | 1 | 1440×900 | light | balanced | columns | 1.188秒 | PASS |
| 3日 | 8 | 1440×1000 | dark | detailed | columns | 0.596秒 | PASS |

全6件で`layout_metrics_applied=true`、`selection_matches=true`、
`history_window_count=1`でした。12時間・24時間はraw、3日はoneMinuteを読み、
各期間の既存保存規則も維持しています。

## 回帰試験と公開境界

| 試験 | 観測結果 |
|---|---|
| 表示設定の決定的試験 | 8/8 PASS |
| 全回帰テスト | 125/125 PASS |
| `swift format lint --strict` | 警告・違反0 |
| arm64 Release build | PASS |
| Intel x86_64 Release build | PASS。buildのみで実機実行は未検証 |
| 画面fixture | 6/6 PASS、全件2秒以内 |
| 公開境界scan | 端末固有path、認証情報、非公開ログ、内部実行手段の痕跡0 |
| 通信・通知API scan | 新規0件 |

## 工程19完了ゲート

- [x] 現在値領域、余白、カード幅、各グラフ高さへ設定を適用
- [x] 780・1080・1440pxでstacked・columnsを確認
- [x] 1・8・16・32論理CPUで履歴と現在値を確認可能
- [x] light・darkと3プリセットを実アプリで確認
- [x] 12時間・24時間・3日の期間と保存解像度を維持
- [x] 時刻選択と単一ウインドウ表示を維持
- [x] 初期表示が全6件で2秒以内
- [x] 全125テスト、Release build、strict format lintがPASS
- [x] 通信、通知、計測、SQLite、保持期間、gapの意味を変更していない
- [x] 公開情報漏洩scanがPASS
- [ ] 工程19の非merge commitが`main`からちょうど1個
- [ ] ready Pull Request、merge commit、GitHub remote main読戻しが完了

最後の2項目は工程commit作成後にだけ観測できます。GitHubでの保存と読戻しが
完了するまでは工程20へ進みません。
