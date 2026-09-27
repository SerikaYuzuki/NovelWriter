# macOS DMG 配布の実装・受入

## 目的

協力者へ macOS 14 以降向けの FUMINIWA を DMG で直接渡す。端末 SQLite の保存、既存の Apple アカウントによる認証、自宅サーバーの Snapshot Sync v2 を維持し、Google ログインも追加する。配布物は Developer ID で署名・公証し、別 Mac の新規利用者環境で起動と同期を確認する。GitHub への公開は今回の対象ではない。

## 配布物と確認記録（2026-09-27）

- Mac 0.1.0 (5)、macOS 14以降、Intel / Apple siliconのUniversal版を作成した。Macのnative Apple entitlementを除去し、Apple / Googleをブラウザ認証へ接続した。
- Developer ID Applicationで署名、hardened runtimeを有効にした。XcodeのDirect Distributionで公証成功（build 5 submission `7F187B5F-5036-497D-9FFE-4F24258292DF`）。書き出したアプリとDMG内のアプリ双方で`stapler validate`成功、Gatekeeperは`accepted / Notarized Developer ID`。
- 配布物は`~/Downloads/FUMINIWA-0.1.0-macOS.dmg`。公証済み・ticket添付済みアプリ、Applicationsリンク、案内文を格納したDeveloper ID署名付きDMG。DMG自体を別途公証に提出したものではない。DMGチェックサムと署名の検証は成功。build 1の旧DMGは`~/Downloads/FUMINIWA-Distribution-20260927/old-build1/`へ退避し、配布パスをbuild 5へ差し替えた。
- 公証済みアプリをこのMacで起動し、既存sessionの復元、既存作品一覧とサーバー接続表示を確認した。
- `Scripts/check.sh`で契約検査・lint・NovelKitテスト・iOS compileを確認した。Mac layoutの不具合とテスト用通信通知の競合、Mac専用viewのiOS target混入を修正し、止まった段階から同じ検証を再実行した。最終結果はMac 185件、iOS EditorKit 86件、iOSアプリ145件が成功。iOS版はApple nativeを維持してGoogle browserを追加し、iOSシミュレータでbuild / install / launchと両ログインボタンの表示を確認した。
- サーバーは暗号化backupの隔離復元でmigration 0010を事前検証した後、本番へ反映済み。既存作品・snapshot・object・account数の保持、health、既存認証capabilities、公開HTTPS経由でApple / Googleの認証開始・pending・誤った引換秘密の拒否・取消を確認した。
- build 1には認証完了callbackでのSwift actor isolation違反があった。SafariLaunchAgentのXPC queueからMainActorを継承したclosureへ入る際に`_dispatch_assert_queue_fail`となる実クラッシュを確認した。build 2では非隔離のSendable入口で通知を受け、MainActorへ移ってから結果を適用する。
- build 2でApple Webログイン完了、既存作品の再表示とサーバー接続を確認した。サーバーのaccount数は1のまま、Web audienceのactive Apple credentialが1件となり、既存AccountIDへの復帰を確認した。共有コードの成功・取消をbackground queueから呼ぶ回帰テストも成功。
- build 5は右AIパネルのドラッグ伸縮・端末内の幅保持と、同一account再ログイン後の同期base復元も含む。幅360→520ptの実ドラッグ、496ptへの調整後の開閉保持、build 5の再起動後の復元と496→536ptのドラッグを確認した。狭いウインドウではnative列の最小幅を伝え、パネルを画面外へ押し出さない。
- 再ログイン時に破棄されたhead cacheは、同じserver / epoch / account / fenceの検証済みreceiptとcandidateの祖先に限定して復元する。再ログイン後の編集保持を隔離テストで確認した。ローカルDBをbackupし、既存store APIで止まっていた同一commandの再送を要求した。作品・resource・snapshot・親子関係が変更されていないことを比較し、起動後に6作品のhead確認と再試行した送信intentのacknowledgeを確認した。旧commandと旧intentの隔離記録は保持した。
- 未確認: Googleログイン完了、Mac / iOS間の実機同期、別Macの新規環境からのインストール。

## 配布版の認証境界

- Mac 配布版は Apple の Web 認証をシステムの認証ブラウザで開始する。iOS/iPadOS の native flow は維持する。
- Apple Developer に Services ID を登録し、既存 Apple App ID の primary group に関連付ける。登録済み HTTPS return URL は公開サーバーだけに置く。Services ID、primary App ID、return URL の実値は Apple Developer の設定から read-back して確定する。
- サーバーは `state`、`nonce`、単回使用コード、token audience、issuer、subject、期限を検証する。ブラウザからアプリへ Apple code、identity token、FUMINIWA token を URL で渡さない。
- コールバックは単回使用とし、サーバー上に短命の暗号化session応答を保持する。引換券の取得には、開始時にアプリだけが保持した検証値を要求し、期限切れ・別開始操作を拒否し、同じ秘密の再送だけは同じ応答を返す。引換券や認証情報はログ、URL履歴、作品、通常保存 DB に残さない。
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
4. Developer IDで署名・公証・stapleしたアプリを、署名付きDMGへ格納する。署名、Gatekeeper、DMG からのインストール・起動を別 Mac の新規利用者環境で確認する。
5. 協力者にはサーバーが原稿を読める方式であることと、試験作品から始めることを伝え、DMG を直接渡す。

各段階は独立に記録する。Archive 成功は配布物の完成を意味しない。
