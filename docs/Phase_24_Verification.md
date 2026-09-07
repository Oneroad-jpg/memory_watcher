# 工程24 Developer ID署名・公証 検証記録

## 工程の範囲

工程24は、Memory Watcher v0.3.3をMac App Store外で安全に配布するため、
Developer ID署名、Hardened Runtime、安全なタイムスタンプ、Appleの公証、
公証チケット添付、Gatekeeper評価、インストール後の実記録読戻しを行う工程です。

メモリ・CPUの測定式、5秒間隔、SQLite schema、12時間・24時間・3日の保持、
表示構成、通知・通信境界は変更していません。認証情報、公証のsubmission ID、
端末固有パス、公証の非公開ログは公開物へ含めません。

## 署名・公証結果

| 項目 | 観測結果 |
|---|---|
| version / build | 0.3.3 / 1 |
| 署名 | `Developer ID Application`、strict verify PASS |
| Hardened Runtime | `Runtime Version`を確認 |
| 安全なタイムスタンプ | `Timestamp`を確認 |
| debug entitlement | `com.apple.security.get-task-allow=true`なし |
| 公証応答 | `Accepted`、status code 0、issueなし |
| チケット添付 | `stapler staple` / `stapler validate` PASS |
| Gatekeeper | `accepted`、`source=Notarized Developer ID` |
| ZIP展開後の再検証 | codesign / stapler / Gatekeeper PASS |
| 配布ZIP SHA-256 | `861079b48b6d7c2ba6d5424683917b375044824d3f5d88a22acc7aeae692844c` |

Appleが公証を受理した後にローカルの認証プロファイル読出しが中断したため、
同じZIPを再送信せず、既存submissionの状態読戻しからチケット添付を再開しました。
これにより公証の二重送信を避けています。

## 安全な更新とincident修正

既存版と候補版が異なる場合の無条件上書きは維持せず、明示的に更新を許可した
場合だけ次の処理を行うインストール経路を追加しました。

- 候補版の署名、公証チケット、Gatekeeper評価を置換前に検証する
- 起動中のアプリは置換せず終了コード付きで停止する
- 旧版を復旧可能な場所へ退避してから新しいアプリを導入する
- 導入後の署名、公証、実行ファイル、Info.plist、署名資源を再照合する
- 導入途中で失敗した場合は旧版を自動復元する

初回更新では、旧版が起動中だったため置換前の安全条件が作動しました。その終了
経路でzshの予約変数`status`との名前衝突を検出しました。trap内の変数だけを
`exit_code`へ変更し、同じ起動中拒否を再実行して、二次エラーが再発せず終了コード7
で停止することを確認しました。その後、旧版を通常終了して更新を完了しました。

## インストール後の実記録読戻し

| 項目 | 観測結果 |
|---|---|
| インストール済みversion | 0.3.3 / build 1 |
| 起動 | インストール済み実行ファイルが継続動作 |
| 旧版 | 更新前の0.3.2を復旧可能な状態で保持 |
| メモリ記録 | 起動後の最新UTC時刻へ進行 |
| Mac全体CPU記録 | 起動後の最新UTC時刻へ進行 |
| 論理CPU別記録 | 起動後の最新UTC時刻へ進行 |
| SQLite `integrity_check` | `ok` |
| インストール後の公証評価 | stapler / Gatekeeper / strict codesign PASS |

起動時の保存期限整理により保持対象外の古い行が削除されるため、単純な全行数では
なく、各テーブルの最大UTC時刻が起動前より新しくなったことを記録継続の判定に
使用しました。画面の`RUNNING`表示だけを記録成功の根拠にはしていません。

## 回帰・公開境界

| 項目 | 観測結果 |
|---|---|
| 全回帰テスト | 134/134 PASS |
| shell syntax | build / notarize / installの3スクリプトがPASS |
| diff whitespace | `git diff --check` PASS |
| 認証情報 | ソース、文書、ZIPへ保存していない |
| 公開対象外 | submission ID、端末固有パス、非公開公証ログ |

配布ZIP内のアプリはApple Silicon用です。ソースはIntel向けにbuild可能ですが、
Intel実機でのv0.3.3動作とUniversal Binaryの配布はこの工程では未検証です。

## 工程24完了ゲート

- [x] Developer ID、Hardened Runtime、安全なタイムスタンプで署名した
- [x] debug entitlementを含まないことを確認した
- [x] 公証結果がAcceptedでissueなし
- [x] 公証チケットを添付し、ZIPを再生成した
- [x] ZIP展開後も署名、公証、Gatekeeper評価がPASSした
- [x] 安全な更新と失敗時復元経路を実装した
- [x] 起動中拒否の終了処理incidentを限定修正し、再発試験を通した
- [x] インストール済み0.3.3が起動して新規記録を書いた
- [x] SQLite整合性と全134テストがPASSした
- [x] 公開物へ認証情報、submission ID、端末固有情報を含めない

工程24の実装は1個の非merge commitへまとめ、ready Pull Request、merge commit、
GitHub remote readbackを経て完了とします。

## GitHub Release公開後の読戻し

2026-09-07に
[GitHub Release v0.3.3](https://github.com/Oneroad-jpg/memory_watcher/releases/tag/v0.3.3)
を公開し、公開先から配布ZIPを新しい一時領域へ再ダウンロードしました。

| 項目 | 公開後の観測結果 |
|---|---|
| Release | public、非draft、非prerelease、Latest |
| asset | `MemoryWatcher-0.3.3.zip`、818,209 bytes、uploaded |
| GitHub asset digest | `sha256:861079b48b6d7c2ba6d5424683917b375044824d3f5d88a22acc7aeae692844c` |
| 再ダウンロードSHA-256 | 工程24の配布ZIP SHA-256と一致 |
| ZIP整合性 | 全項目OK |
| 展開後署名 | strict codesign PASS |
| 展開後公証 | `stapler validate` PASS |
| 展開後Gatekeeper | `accepted`、`source=Notarized Developer ID` |
| version / architecture | 0.3.3 / arm64 |

これにより、ローカル候補の検証とGitHub上の公開配布物の検証を分けたうえで、
同一バイトの公開と読戻しを確認しました。
