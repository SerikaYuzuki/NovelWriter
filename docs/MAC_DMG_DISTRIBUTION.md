# macOS DMG 配布の実装・受入

## 目的

協力者へ macOS 14 以降向けの FUMINIWA を DMG で直接渡す。端末 SQLite の保存、既存の Apple アカウントによる認証、自宅サーバーの Snapshot Sync v2 を維持し、Google ログインも追加する。配布物は Developer ID で署名・公証し、別 Mac の新規利用者環境で起動と同期を確認する。GitHub への公開は今回の対象ではない。

## 現在の障害

Mac アプリは `com.apple.developer.applesignin` を要求し、AuthenticationServices の native flow だけを実装している。Apple の Developer ID provisioning profile は Sign in with Apple capability を許可しないため、現行 Archive を Direct Distribution で書き出せない。DMG への梱包では解消しない。

2026-09-27 のローカル Keychain 再確認では `Developer ID Application: Kisei Matsumoto (Z699T95YH7)` が署名可能な identity として表示された。署名・公証・Gatekeeper 受入は未実施。

## 配布版の認証境界

- Mac 配布版は Apple の Web 認証を既定ブラウザで開始する。iOS/iPadOS の native flow は維持する。
- Apple Developer に Services ID を登録し、既存 Apple App ID の primary group に関連付ける。登録済み HTTPS return URL は公開サーバーだけに置く。Services ID、primary App ID、return URL の実値は Apple Developer の設定から read-back して確定する。
- サーバーは `state`、`nonce`、単回使用コード、token audience、issuer、subject、期限を検証する。ブラウザからアプリへ Apple code、identity token、FUMINIWA token を URL で渡さない。
- コールバックではサーバー上の短命・単回使用の引換券だけを発行する。引換券の取得には、開始時にアプリだけが保持した検証値を要求し、期限切れ・再利用・別開始操作を拒否する。引換券や認証情報はログ、URL履歴、作品、通常保存 DB に残さない。
- Apple の verified subject が既存 native flow と同じ AccountID に戻ることを隔離環境と実アカウントで確認する。異なる subject になった場合は既存作品を自動採用・統合しない。
- Apple token と FUMINIWA token は既存の server vault / 端末 Keychain の責務を維持し、同期 API の Bearer に Apple token を使わない。認証中も端末の編集・保存を止めない。

## Google とアカウント分離

- Google 認証もシステムブラウザを使用し、OpenID Connect の署名、issuer、audience、期限、nonce、subject をサーバーが検証する。表示名・メールアドレスを AccountID の判断に使わない。Google OAuth の embedded browser 禁止を守る。
- FUMINIWA の 1 AccountID に対して認証方法は Apple か Google の一方だけとする。Google subject は Apple subject と別の AccountID へ対応させる。明示連携・自動連携のどちらも提供しない。
- 同じメールアドレスでも account・作品を統合しない。認証方法を切り替えた場合、現在の端末作品を別 AccountID へ自動採用せず、既存の account transition と保全境界を守る。
- Google Cloud の OAuth client と consent 画面、公開ホームページ・プライバシー情報を設定する。必要な実値は管理画面から確認して確定し、client secret はサーバーだけに置く。

## 配布の確認順

1. Apple Web / Google 認証と account 分離の契約、schema、fixture、Mac 実装、サーバー実装をそろえる。既存 native client とその session を壊さない。
2. 合成データで認証の成功、取消、再送、失効、別開始操作、account 切替、悪意ある callback、サーバー再起動を検証する。`Scripts/check.sh` と該当する実 DB 統合試験を通す。
3. Apple Developer の Services ID / primary group / return URL と Google Cloud の OAuth 設定を確認し、サーバーの backup と切り戻し手段を確保して反映する。署名済み Mac アプリで Apple ログインと同じ AccountID、Google の独立アカウント、同期 scope を確認する。
4. Developer ID で署名、公証、staple した DMG を作る。署名、Gatekeeper、DMG からのインストール・起動を別 Mac の新規利用者環境で確認する。
5. 協力者にはサーバーが原稿を読める方式であることと、試験作品から始めることを伝え、DMG を直接渡す。

各段階は独立に記録する。Archive 成功は配布物の完成を意味しない。
