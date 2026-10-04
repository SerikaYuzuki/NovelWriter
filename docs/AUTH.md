# 認証の現在の境界

Mac の Developer ID 配布版とiOSで使う Apple Web / Google ブラウザ認証は[Auth v2 契約](auth/v2/README.md)に分けて記す。下記は既存 Auth v1 の境界であり、ブラウザ入口も同じアカウント・セッション基盤を使う。

Auth v1でAppleログインからFUMINIWA sessionを発行し、Snapshot Sync v2で使用する。wireの正本は[Auth v1](auth/v1/README.md)と[OpenAPI](auth/v1/openapi.yaml)。Auth epochは1、Sync epochは2で、両者を混同しない。

## 実装

| 責務 | 場所 |
| --- | --- |
| Swift session・HTTP・Keychain | `NovelKit/Sources/NovelAuth/` |
| native Apple認証 | `NovelKit/Sources/NovelAuthApple/` |
| Rust provider・session・永続状態 | `SyncServerV2/src/auth*.rs` |
| account切替とローカル保全 | `NovelWorkspace.AccountTransitionCoordinator`、両AppのIME／SQLite／UI adapter、共通v2 application/store |
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


## 両OSのaccount transition（D-115）

復元、Apple／Google sign-in、sign-out、A→B、refresh、revoke retryは共通Coordinatorを通す。request windowで旧accountのwork／AI completionを無効化し、remote suspension leaseを最初のIME／dirty checkpoint前に取得する。sign-inはpreflight→旧scopeのdurable park→exchange→destinationのdurable反映の順。exchangeがvaultへ先にBを保存して失敗した場合はvaultのBを優先して回復し、未確定なら元のAを回復する。sessionはSQLiteのaccount boundaryが成立した後にだけUIへpublishする。park・反映が失敗した場合は原稿と既存sessionを保持する。

leaseは成功、IME拒否、交換失敗、取消、復元失敗、旧epoch fail-closedで解放する。abandon recoveryはlive exchangeを奪わず、取消cleanupは元のownerだけを解放する。exchange中もdurable park後はローカル編集・作品操作を許可し、sign-out要求はexchange終了後に実行する。Macのinteractive countはこの短い準備／document境界から導出する。同一scopeのrefreshはgeneration、work／AI request、account UIを保持する。

未ログインからの失敗は理由付きfailed、取消はsignedOut。回復したsessionが残る失敗は別noticeで理由を保つ。sign-outは既存vaultでrevoke journalを確定し、callerとleaseを解放してから独立taskでjournalを再送する。launch／foreground retryは新しいBを保持し、`signOut()`を再帰呼出ししない。

旧Sync epochはUI／runtimeへpublishせず、本文・履歴を保持して全persisted laneをparkする。直接transitionはfailedとfalseを返す。launch restoreはpark成功後に使用不能な旧vault sessionを除去する。native Apple credential-stateのrevoked／notFound／transferredはsignedOut、照合のoffline／一時失敗はsession復元を妨げない。ブラウザ由来sessionにはnative照合を適用しない。

認証compositionはMac productionのApple browserとiOS nativeを維持し、Googleは両OS browser。session Keychain serviceはMac `dev.serikayuzuki.fuminiwa.sync`、iOS `dev.serikayuzuki.fuminiwa.sync.ios`、item accountは`session`。Apple handle vaultは`jp.fuminiwa.apple-credential-state`と既存provider configurationを維持する。`KeychainAuthSessionVault`／`AuthVaultRecord`のserialization、clientPlatform（Mac `.macos`、iOS `.ios`）、clientVersion `0.1.0`、limitsの6値に変更はない。生token／subject／HTTP bodyをログ・UserDefaultsへ残さない。

共通conformanceの18シナリオを`NovelWorkspaceTests`のfakeと両App test adapterで実行する。実AppではleaseをIME callback時に観測し、dirty titleのSQLite read-back、park、account UI消去、実work／AI取消、refresh保持、回復と終了時のlease解放を検査する。Apple入口の構成差は`AuthCompositionTests`で検査する。test-only provider／browser callbackと隔離runtimeによるローカル検証であり、既存ユーザーKeychain、外部OAuth、署名済み実機受入を含まない。実機ではMac browser／iPhone nativeのApple、両OS Google、認証中sign-out、A→B、ログイン中の再起動を別途確認する。


P10のローカル検証は`./Scripts/check-changed.py --base codex/workspace-p10a`で実施し、失敗した段階を`--step`で再開した。後続の修正は関係するpackage target／App段階だけを再確認した。SwiftFormat、SwiftLint、D-076、target依存、network／AI／v2境界、project生成が成功。packageはNovelWorkspace 91、NovelWorkspaceUI 41、NovelAuth 63、SyncV2Application 221、SyncV2Store 165件が成功した。macOS Appは210定義／263実行成功・4skip、iOS Simulator Appは154定義／186実行成功・3skipで失敗0。共通18シナリオは各Appのxcresult test treeで18/18 Passedを確認した。`check.sh`はP10終端のorchestrator担当として未実施。

最終xcresultは`Test-FUMINIWA-2026.10.04_22-45-15-+0900.xcresult`と`Test-FUMINIWAIOS-2026.10.04_22-45-42-+0900.xcresult`。実Keychainの既存item受入、外部OAuth、署名済み実機、deployment／公開は未実施で、skipを受入成功へ数えていない。
