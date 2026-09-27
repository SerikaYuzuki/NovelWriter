# Auth v2: Mac・iOS のブラウザ認証契約

## 状態と範囲

ブラウザ入口をサーバーとMac / iOSへ実装した。公開環境と実アカウントの受入は下記記録で区別する。既存の Auth v1 native Apple 認証、発行済み session、Snapshot Sync v2 の wire と AccountID は変更しない。Mac の Developer ID 配布版で Apple Web と Google OpenID Connect、iOS / iPadOS で現行 native Apple と Google OpenID Connect を使うための新しい認証入口を設ける。既存のAuth v1 capabilitiesとsession / refresh wireを維持し、ブラウザ入口だけを`/v2/auth/browser/`へ追加する。[OpenAPI](openapi.yaml)を参照。

## 開始から session 取得まで

1. Mac アプリが provider (`apple` または `google`)、iOS / iPadOS アプリが `google` と、端末内で生成した 256-bit の引換秘密のハッシュを HTTPS でサーバーに送る。サーバーは短命の attempt、推測不能な `state` と `nonce`、認可 URL を作り、attempt ID と URL だけをアプリに返す。
2. アプリが URL を`ASWebAuthenticationSession`で開く。認可 URL の `redirect_uri` は provider に登録した固定 HTTPS callback と完全一致させる。Apple は `https://sync.serika.work/v2/auth/browser/apple/callback` を登録した Services ID、Google は `https://sync.serika.work/v2/auth/browser/google/callback` を登録した Web application OAuth client を使用する。
3. callback は `state`、有効期限、単回使用を先に検査する。サーバーが provider の code を token endpoint で引き換え、ID token の署名、issuer、audience、期限、nonce、subject を検証する。provider の code、ID token、FUMINIWA token をブラウザからアプリへ URL で渡さない。callback は固定の`fuminiwa-auth://complete`へ戻す。戻りURLに認証情報やattempt IDを含めない。
4. アプリだけが attempt ID と引換秘密で完了を問い合わせる。callbackは一度だけsessionを発行し、暗号化した応答をattemptの残り有効期間内だけ保持する。同じ引換秘密による再送は同じsession応答を返し、二重発行しない。FUMINIWA sessionはTLSのレスポンス本文だけで返す。未完了は202、取消・期限切れ・不正な秘密は400とする。callback再使用を拒否し、サーバー再起動後も暗号化receiptを同じ秘密で取得できる。アプリ再起動では秘密を復元せず、新たに認証する。引換秘密、provider credential、FUMINIWA token はログや通常保存 DB に残さない。
5. アプリは既存の Keychain と account transition gate を通して session を導入する。別 AccountID のローカル作品は自動採用しない。認証待ちの間も SQLite 保存と編集を続けられる。

## アカウントの対応

- Apple Web の verified subject は、同じ primary App ID に属する既存 native Apple identity と照合し、同一人物の AccountID を保つ。subjectが異なる場合は別アカウントとして扱い、既存作品を移動・統合しない。実アカウントでの一致は配布受入として別途確認する。
- Google の identity key は Google issuer と verified subject に基づき、Apple identity とは別の AccountID にする。email、表示名、端末からの申告値を identity key にしない。
- 1 AccountID に active な provider kind は一つだけとし、DB 制約と同一 transaction 内の確認で守る。provider の連携・変更・account merge は提供しない。Google でサインインした端末から Apple で入り直す操作は、通常の account 切替として扱う。
- Google の要求 scope は認証に必要な最小限にし、Google の長期 access / refresh token を FUMINIWA の同期 token として保存しない。Apple の credential と失効通知は既存の保全規則を維持する。

## 外部設定と受入

- Apple Developer の Services ID は `dev.serikayuzuki.fuminiwa.web`。所有者は primary Mac App ID への関連付け、`sync.serika.work`、上記 return URL の保存完了を報告した。設定画面のread-backは未実施だが、修正版build 2でApple Webの実認証が完了し、既存AccountIDに戻ることを確認した。Google Cloud project ID は所有者申告で `eco-shift-452410-t2`、14:08 作成の OAuth client ID は `560354700432-aq87npqhidi1m4n671m8pb9bugml609d.apps.googleusercontent.com`。ダウンロード済み Web client JSON で client ID、callback、secret の存在を照合し、ファイル権限を所有者読み書きだけにした。秘密鍵と client secret はサーバーの secret 管理に置き、repo と DMG に含めない。Google の実認証は未確認。
- callback は provider ごとに固定し、認可 URL・token request と登録値の完全一致を確認する。`state` / `nonce` 不一致、期限切れ、code 再使用、cross-attempt、provider 取り違え、重複 callback、サーバー再起動を合成データと実 DB で確認する。
- 既存 Apple native client の認証・更新・削除操作が回帰しないことを確認する。Apple Web で既存 AccountID に戻ること、Google で独立 AccountID になること、同期 scope と端末ローカル作品の保全を実アカウントで確認する。

## 実装・検証記録（2026-09-27）

- `auth_browser.rs`、`auth_postgres_browser.rs`、migration 0010がブラウザ入口と既存session発行を接続する。1アカウントにactive identityは一つとするunique indexを追加した。ブラウザ機能は`FUMINIWA_BROWSER_AUTH_ENABLED=1`で有効化し、Google secretはファイルから読み込む。Composeでは`docker-compose.browser.yml`を追加する。
- attemptは5分、DB全体で有効なattemptを最大1000件に制限する。stateはhash、引換秘密はSHA-256 hashだけを保持し、provider subjectとreceiptは既存vaultで暗号化する。Googleの長期provider tokenは保存しない。
- MacはApple / Googleともブラウザ、iOSはApple native / Google browser。Macのnative Apple entitlementを除去した。両Appとも既存の原稿保全・account transitionを共用する。
- ローカルの`Scripts/check.sh`（Mac / iOSテストを含む）は成功。隔離DBで既存Auth v1 scenario、GoogleのMac / iOS AccountID共有、Appleとの分離、引換秘密不一致、provider取り違え、取消、期限切れ、receipt再送、active identity制約を確認した。Google署名改ざん、nonce不一致、clientのattempt不一致も対象テストで確認した。
- 暗号化backupの隔離復元でschema 9→10、migration / runtime role検証と作品件数の保持を確認し、本番へ反映済み。公開HTTPSで両providerのstart / pending / 不正claim / 取消を確認した。稼働イメージは`sha256:bd88d1f42108961bdf738971e3ca3cdcfef2b390b3295e1ebc22bc6a81032067`。
- Apple Webの署名検証、nonce拒否、provider refresh credentialの暗号化保存も対象テストで確認した。Rust libは34成功、隔離DBの明示実行用1件は別途成功。
- 公証とDMG検証は[配布記録](../../MAC_DMG_DISTRIBUTION.md)を参照。Apple Webの実認証と既存AccountIDへの復帰はbuild 2で確認済み。Googleログイン完了と実機同期は未確認。
