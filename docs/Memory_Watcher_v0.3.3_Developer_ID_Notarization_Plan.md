# Memory Watcher v0.3.3 Developer ID署名・公証工程表

## 目的

Memory WatcherをMac App Store外で安全に配布できるようにし、Appleの
Developer ID署名、公証、チケット添付、Gatekeeper検証を一貫して行う。
既存のv0.3.2リリースは変更しない。

## 対象範囲

- `Developer ID Application`によるアプリ署名
- Hardened Runtime
- Appleの安全なタイムスタンプ
- `notarytool`によるZIPの公証申請
- 公証ログの読戻し
- `.app`への公証チケット添付
- Gatekeeperによる最終評価
- 認証情報をリポジトリと配布物へ含めない運用

インストーラ用PKG、Mac App Store配布、自動更新、課金機能は対象外とする。

## 工程と完了条件

### 24.1 証明書準備

Xcodeから`Developer ID Application`証明書を発行し、秘密鍵とともに
ログインキーチェーンへ保存する。

完了条件:

- Xcodeの証明書一覧に`Developer ID Application`が表示される
- `security find-identity -p codesigning`で有効な署名IDとして読める
- 証明書の秘密鍵や認証情報をリポジトリへ保存していない

### 24.2 再現可能なDeveloper ID署名

リリースビルドへHardened Runtimeと安全なタイムスタンプを付けて署名する。
開発用のアドホック署名経路は維持する。

完了条件:

- `codesign --verify --deep --strict`が成功する
- Authorityが`Developer ID Application`である
- `Runtime Version`と`Timestamp`が署名情報に存在する
- `com.apple.security.get-task-allow=true`を含まない

### 24.3 公証申請

キーチェーンに保存した名前付き認証プロファイルだけを使い、署名済みZIPを
`notarytool`へ送信する。

完了条件:

- 認証情報をコマンド引数、ソース、Git、配布ZIPへ保存しない
- 複数プロセスで使う場合はファイルベースのログインキーチェーンを明示する
- 公証応答が`Accepted`である
- submission IDを取得できる
- 公証ログを保存して警告とissueを確認できる
- 受付後に中断した場合、既存submission IDから復帰して重複送信しない

### 24.4 チケット添付と配布物再生成

受理された`.app`へ公証チケットを添付し、添付後のアプリから配布ZIPを
再生成する。

完了条件:

- `stapler staple`が成功する
- `stapler validate`が成功する
- `spctl --assess --type execute`が成功する
- 添付後ZIPのSHA-256を記録できる

### 24.5 回帰・公開

署名と公証によってMemory Watcherの既存機能が退行していないことを確認し、
新しい不変リリースとして公開する。

完了条件:

- 全Swiftテストが成功する
- インストールした署名済みアプリが起動する
- 新しい測定値を保存し、履歴として読み戻せる
- ソースと配布物の公開情報漏洩スキャンが成功する
- 1つの実装commit、ready PR、merge commit、GitHub remote readbackが完了する
- GitHub ReleaseのZIPと記録済みSHA-256が一致する

## HOLD条件

次のいずれかを検出した場合は、公開や既存アプリの置換をせず停止する。

- Developer ID署名、Hardened Runtime、安全なタイムスタンプの欠落
- 公証結果が`Accepted`以外
- 公証ログのissueまたは説明不能な警告
- `stapler`またはGatekeeper評価の失敗
- テスト失敗、起動失敗、記録・読戻し失敗
- 認証情報、ローカル固有情報、非公開ログの混入
