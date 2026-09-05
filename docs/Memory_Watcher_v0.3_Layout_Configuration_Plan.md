# Memory Watcher v0.3 ローカル表示構成工程表

## 目的と範囲

v0.3は、広いウインドウの余白を減らして一覧性を上げ、表示密度・順序・任意項目を
アプリ内で調整できるようにします。設定はこのMacだけに保存し、外部CMS、通信、
クラウド同期、AIは追加しません。メモリ・CPUの測定、SQLite、保持期間、gapの意味は
v0.2から変更しません。

進行順は固定します。

`18 表示契約 → 19 適応レイアウト → 20 構成エディタ → 21 最終検証・アプリ化`

| 工程 | 実装内容・成果物 | 完了条件 |
|---|---|---|
| 18. 表示構成要件と設定契約 | 「CMS」をローカル表示構成エディタとして定義する。3プリセット、セクション順、任意セクションの表示状態、schema version、既定値、異常設定の回復規則を型と文書へ固定する。 | 必須表示と変更可能項目が区別されている。プリセット値がすべて正の安全範囲にあり、compact・balanced・detailedの順で情報密度が変わる。重複・欠落・必須項目の非表示・未知schemaを決定的テストで処理できる。全テスト、Release build、strict format lint、公開境界scanがPASS。単一commit、ready PR、merge、remote readbackを完了する。 |
| 19. 適応レイアウトとプリセット表示 | 現在値領域、余白、カード幅、各グラフ高さへ設定を適用する。ウインドウ幅に応じたcolumns・stacked配置を維持し、compactで不要な空きを減らす。 | 780・1080・1440px、1・8・16・32論理CPU、light・darkで欠けや重なりがない。3プリセットすべてで必須項目を確認できる。期間・時刻選択・gap表示・監視継続を退行させない。初期表示2秒以内、strict lintと全回帰試験がPASS。単一commit、PR、merge、remote readbackを完了する。 |
| 20. アプリ内表示構成エディタ | 同じウインドウから設定sheetを開き、プリセット、順序、任意セクションの表示、resetを操作する。schema付き設定をUserDefaultsへ保存する。 | マウス、キーボード、VoiceOverで操作できる。変更が即時反映され、監視エンジンとDB接続を再生成しない。再起動後に設定が戻り、壊れた保存値はbalancedへ回復する。resetで標準順・全表示へ戻る。通信・通知0。単一commit、PR、merge、remote readbackを完了する。 |
| 21. 回帰監査・アプリ化 | 実履歴で3プリセットと保存・復元を確認し、表示中・非表示中の軽量性、署名、ZIP、履歴読戻しを検証する。 | 12時間・24時間・3日、sleep・UNKNOWN・gap、メモリ・全体CPU・論理CPUを読戻せる。表示・非表示各30分の平均CPU1%未満、RSS単調増加なし、SQLite整合性`ok`、Internet socket 0、保持DB上限内。Apple Silicon実機とIntel buildを区別する。全試験PASS後に単一commit、ready PR、merge、remote readbackを完了する。 |

## 停止規則

- incident、説明不能な表示差、計測・履歴の退行、テスト失敗、CPU 1%以上、
  SQLite不整合、通信・通知API、公開情報漏洩を検出した工程で停止する。
- UI設定を理由に測定値、欠落、UNKNOWN、sleep区間を補正しない。
- 各工程は1個の非merge commit、ready Pull Request、merge commit、
  GitHub remote mainの読戻しを完了してから次へ進む。
- 工程21は表示層だけの変更であることを確認できるため、新たな24時間監査は増やさず、
  表示・非表示各30分の実運転とv0.2の保存・監査回帰で判定する。

設定値の正本は
[Dashboard Layout Contract v1](Dashboard_Layout_Contract_v1.md)とします。
