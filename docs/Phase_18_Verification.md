# 工程18 表示構成要件・設定契約 検証記録

## 工程の範囲

工程18は表示構成の意味、変更可能範囲、既定値、異常設定からの回復を固定する工程です。
画面への適用は工程19、編集UIと永続化は工程20、実運転監査は工程21で行います。

## 固定した契約

- [x] 「CMS」を外部サービスではなくローカル表示構成エディタとして定義
- [x] `compact`・`balanced`・`detailed`の3プリセットを固定
- [x] 現在値領域、余白、間隔、カード幅、各グラフ高さをプリセット値として固定
- [x] メモリ履歴とMac全体CPUを非表示不可に固定
- [x] 論理CPU別履歴と選択時刻詳細だけを任意表示に固定
- [x] 既知セクションの順序変更、重複除去、欠落補完を固定
- [x] schema version 1とローカル保存keyを固定
- [x] 未知schemaでは推測せずbalanced既定値へ戻す
- [x] 計測、SQLite、保持期間、gap、通信・通知の境界を変更しない

詳細は
[Dashboard Layout Contract v1](Dashboard_Layout_Contract_v1.md)に保存します。

## 決定的試験

`DashboardLayoutConfigurationTests`は次を検証します。

1. 既定値がbalanced・標準順・全表示である
2. 全プリセット値が正の範囲で、密度順が逆転しない
3. セクション重複を除き、欠落した既知項目を標準順で補う
4. メモリ履歴とMac全体CPUを非表示にできない
5. 未知schemaを既定値へ戻す
6. JSON encode・decode後も同じ解決済み設定になる

## 工程18完了ゲート

- [x] 変更可能項目と変更禁止境界を文書化
- [x] 3プリセットの固定値とschema versionをコード化
- [x] 異常設定を推測で補わず、安全な既定値へ解決
- [x] 新規契約テスト6/6、全回帰テスト123/123がPASS
- [x] arm64・Intel x86_64 Release buildがPASS
- [x] strict format lintと公開境界scanがPASS
- [ ] 工程18の非merge commitが`main`からちょうど1個
- [ ] ready Pull Request、merge commit、GitHub remote main読戻しが完了

最後の2項目は工程commitの作成後にだけ観測できます。GitHubでの保存と読戻しが
完了するまでは工程19へ進みません。
