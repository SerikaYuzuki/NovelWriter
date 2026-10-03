# 認証の現在の境界

Mac の Developer ID 配布版とiOSで使う Apple Web / Google ブラウザ認証は[Auth v2 契約](auth/v2/README.md)に分けて記す。下記は既存 Auth v1 の境界であり、ブラウザ入口も同じアカウント・セッション基盤を使う。

Auth v1でAppleログインからFUMINIWA sessionを発行し、Snapshot Sync v2で使用する。wireの正本は[Auth v1](auth/v1/README.md)と[OpenAPI](auth/v1/openapi.yaml)。Auth epochは1、Sync epochは2で、両者を混同しない。

## 実装

| 責務 | 場所 |
| --- | --- |
| Swift session・HTTP・Keychain | `NovelKit/Sources/NovelAuth/` |
| native Apple認証 | `NovelKit/Sources/NovelAuthApple/` |
| Rust provider・session・永続状態 | `SyncServerV2/src/auth*.rs` |
| account切替とローカル保全 | 両AppのAuthentication extension、共通v2 application/store |
| 削除予約・取消・worker | `SyncServerV2/src/account_deletion.rs`、[lifecycle](auth/v1/account-deletion.md) |

## 保つ契約

- Appleで検証したissuer／subjectをserver内でopaque AccountIDとtenantへ対応させる。email・氏名・client指定IDをidentityや回復根拠にしない。
- Apple tokenを同期APIへ渡さない。clientはFUMINIWA access／rotating refresh tokenだけをKeychainに持ち、provider credentialはserver内のcontext-bound暗号化vaultで保持する。
- account fenceはserver instance＋Sync epoch＋AccountID＋AccountAuthEpochへbindする。別account／古い世代の操作を拒否し、失効時も端末の本文・履歴を消さない。
- challenge、exchange、refresh、lost-response retryは永続operation/receiptで再実行を管理する。生token、subject、HTTP error bodyをログ・作品・UserDefaultsへ残さない。
- Apple署名・claim・nonce・audienceを検証し、通知はreceiptとidentity lockで順序を扱う。再ログインと同秒以前の破壊通知はprovider確認を待ち、timeout等で新sessionを失効させない。
- 新loginは同じidentityの古い確認待ちを全audienceで失効させる。Apple revokeは200だけ成功、他は永続retry。詳細は[通知契約](auth/v1/apple-notification.md)。
- serverReadableV1でE2EEではない。TLSとserver管理の保存時保護を使い、権限を持つ運用者・復旧backupは内容を読める。
- 独自回復、identityのlink/unlink・account mergeは提供しない。GoogleはAuth v2ブラウザ入口で別アカウントとして扱う。

## 運用と残件

明示削除は予約から720時間の猶予と取消API、期限到来workerを実装済み。backupは自宅サーバーで毎日暗号化し1暦年保持する。[運用手順](ACCOUNT_RETENTION_OPERATIONS.md)に復元制約と証跡を記す。削除予約・取消のアプリ画面と別機器へのbackup退避は未対応。

Apple通知は、規範の`/v1/auth/providers/apple/notifications`と実装の`/v1/auth/apple/notifications`に差分が残る。実通知の受入・鍵rotation・署名済み実機の一連の認証を、過去のログイン成功だけで完了扱いにしない。

検証の入口は`NovelAuthTests`、`NovelAuthConformanceTests`、Rust auth unit、専用DBの[auth runner](../SyncServerV2/AUTH_INTEGRATION.md)とaccount deletion gate。通常checkから実DBや私的credentialへ接続しない。

保存した端末名は個人を特定しうる情報としてhistory occurrenceだけに保持し、本文・ヘッダ値をログに出さず、アカウント実消去／作品保管期限後の実消去でhistory行とともに消す。
