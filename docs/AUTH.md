# Snapshot Sync Production 認証ハンドオフ

> **状態**: D-077／D-078のProduction認証を実装する前の設計契約。現時点では設計のみで、Rust／Swift認証module、Production session、provider linking UI／APIは未実装。v1で利用者へ出す外部providerは **Sign in with Appleだけ** とし、将来のOIDC provider追加でも内部AccountIDを変えない。

本書は認証module、credential、session、account fence、Apple失効処理の正とする。認証HTTP wireとstate fixtureは[auth/v1/](auth/v1/)、現在liveな同期payload、SQLite／CAS、Conflict、retentionの正は[SNAPSHOT_SYNC_V2.md](SNAPSHOT_SYNC_V2.md)、実装順は[SNAPSHOT_SYNC_HANDOFF.md](SNAPSHOT_SYNC_HANDOFF.md)、同期HTTP bearer境界は[sync/v2/openapi.yaml](sync/v2/openapi.yaml)に従う（`sync/v1/`はarchive）。

### Auth v1 と live Sync v2 のepoch

`authProtocolEpoch=1`／`authProtocolVersion=1.0.0`はAuth wire自体の世代であり、変更しない。一方、現在liveなSnapshot SyncはD-080の新namespaceで`syncProtocolEpoch=2`（Sync v2の`PROTOCOL_EPOCH`）である。Authのcapabilities、exchange、refresh、`/me`が返すsession bindingは常にこのSync v2 epoch `2`を返す。`authProtocolEpoch`と`syncProtocolEpoch`を同じ値として扱わず、AccountFenceはserver instance＋Sync v2 epoch `2`＋AccountID＋AccountAuthEpochへbindする。

## 1. 採択する境界

認証は次の4層を一方向に通す。

```text
External provider credential
    ↓ provider固有の署名・code・claim検証
VerifiedExternalIdentity(providerConfigID, exact issuer, subject)
    ↓ server内のidentity lookup／明示link policy
Immutable opaque AccountID + 1:1 Tenant
    ↓ FUMINIWA独自session発行
FUMINIWA access token / rotating refresh token / account fence
```

- Apple identity token／authorization codeを同期APIのbearerとして使わない。
- AccountIDはprovider subject、email、氏名から導出せず、serverが暗号学的乱数から一度生成する。link／unlink／再認証／fence更新で変えない。
- 同期APIが受け取るprincipalは`AccountID`、内部Tenant ID、FUMINIWA session ID、account-fence generationだけとする。Apple／OIDC claimを`sync-domain`へ出さない。
- request bodyからowner／AccountID／Tenant IDを受け取らず、認証済みprincipalだけがtenantを選ぶ。
- v1はAppleだけを有効化する。provider-neutralなtableとportは先に固定するが、OIDC adapter、provider link／unlink API、account merge、link UIは実装しない。
- development固定Bearer tokenは別の`DevTokenAuthenticator`としてProduction build／configurationからfail-closedで除外し、Production accountの代用にしない。

## 2. Identity、Account、Sessionのstate

| 集約 | state | 遷移契約 |
| --- | --- | --- |
| Account | `active / locked / deletionPending / deleted` | provider失効だけで原稿を削除しない。`deleted`は別の明示account削除workflowだけが確定する |
| External identity | `pending / active / revoked / unlinked / providerDeleted` | 同じprovider＋issuer＋subjectの再接続は同じrow／AccountIDを再利用し、新Accountを作らない |
| Auth attempt | `pending / consumed / expired / rejected` | state／nonce／codeは1回だけconsumeし、lost responseは保存済み結果から回復する |
| FUMINIWA session | `active / reauthRequired / revoked / expired` | provider tokenとは独立。端末単位logoutは他端末sessionを失効させない |
| Refresh-token family | `active / rotated / reuseDetected / revoked / expired` | 1回使用ごとにrotateし、旧token再利用はfamily全体を失効させる |
| Account fence | `current / superseded` | account authorization epoch。通常refreshでは変えず、security boundary変更時だけ世代を進める |

認証不能、provider障害、session expiry、account mismatchはいずれもlocal edit、SQLite autosave、local Snapshot、Import／Exportを止めない。network workerだけを`parkedAuth`または`parkedAccount`へ移す。

## 3. Account fence

account fenceはsession tokenでもprovider identityでもなく、同じAccountIDの認証authority世代を示すopaque値である。

- `AccountFence`は`server instance ID + protocol epoch + AccountID + AccountAuthEpoch`に対してserverが生成する256-bit opaque乱数とし、Account行へ値そのものを耐久保存する。epochを進めるtransactionだけが新しい値を生成し、secret／KMS key rotation、backup restore、process restartだけでは変えない。clientは中身を解釈しない。
- 同一Accountの複数端末へ同じcurrent fenceを返す。access／refresh token更新、通常の再login、端末単位logoutではrotateしない。
- provider link／unlink、provider credential revocation、`account-deleted`通知、全session logout、account lock、account-wideなcredential漏えい対応ではgenerationを進め、既存sessionを失効させる。消費済みFUMINIWA refresh tokenの再利用だけなら該当session familyを失効するが、他sessionとAccountAuthEpoch／Fenceは変えない。account-wide compromiseと判定した別の明示security transitionだけが全session失効＋epoch rotateを行う。
- access tokenは発行時fence generationへbindする。旧token／旧fenceはobject存在、Work、receiptの有無を返す前にrejectする。
- `/v1/capabilities`だけがaccount fence headerなしで現在のAccountID／fenceを返す。AccountIDが同じでもfenceが違えば、clientは旧remote presence、cursor、Intent／Attemptを権威として再利用しない。
- 同一AccountID＋新fenceでは旧network stateをquarantineし、bootstrap、missing照会、read-backから再計画する。別AccountIDでは旧scopeのworkをparkし、loginだけでautomatic adopt／rebindしない。

provider issuerはauth session／auditの属性であり、Work bindingやremote-presence identityへ入れない。同期bindingの正は`server instance + protocol epoch + AccountID + account fence`である。これによりAppleから将来OIDCへ認証手段を変えても作品identityを変えない。

## 4. Rust server module境界

最初から細かいcrateへ分裂させず、依存を次に固定する。

```text
sync-auth
  domain/       AccountID, VerifiedExternalIdentity, state, typed auth error
  application/  sign-in, session, fence, revocation, future link policy
  ports/        ProviderVerifier, CredentialVault, AuthRepository, SessionIssuer
       ↑
sync-auth-apple  Apple code exchange / JWT-JWKS verification / notification / revoke
sync-postgres    auth table, lock order, atomic transition, receipt
sync-api         Axum auth routes + bearer middleware
       ↓
sync-domain      AuthenticatedPrincipalだけを受ける

future: sync-auth-oidc → sync-auth ports
```

provider adapterは成功時に次だけを返す。

```text
VerifiedExternalIdentity
  providerConfigID
  exactIssuer
  subject
  authenticatedAt
  providerCredentialHandle（任意、auth module内部だけ）
```

email、氏名、private relay address、Apple固有credential stateを戻り値へ含めない。`subject`の平文はapplication serviceがlookup HMACとauth-vault用ciphertextを同一transactionへ確定した後にmemoryから破棄する。

`sync-api` middlewareはFUMINIWA access tokenを検証し、`AuthenticatedPrincipal(AccountID, TenantID, SessionID, fenceGeneration)`へ変換する。route handler、PostgreSQL sync transaction、S3 key builderはこのprincipalだけを使い、provider tableをjoinしない。

## 5. PostgreSQL責務

| table | 所有するもの | 禁止事項 |
| --- | --- | --- |
| `accounts` | opaque AccountID、1:1 Tenant ID、state、current AccountAuthEpoch、current opaque fence value／生成時刻 | provider subjectやemailをAccountIDに使わない。secret rotationだけでfenceを変えない |
| `auth_provider_configs` | stable providerConfigID、kind、exact issuer、allowlisted client audience集合、Apple primary App ID grouping、enabled、config version | client指定issuer／audienceや任意Discovery URLを受け入れない |
| `external_identities` | Account FK、providerConfigID、issuer、version付きsubject lookup HMAC、state、linked／revoked時刻 | subject平文、email、氏名を保存しない |
| `external_identity_secrets`（auth-vault） | identity FK、providerConfigID／issuer／subjectのcanonical bytesをまとめたenvelope-encrypted ciphertext、vault key version | 平文をDB列／index／logへ出さず、provider adapter／sync roleから読めるようにしない |
| `provider_credentials` | identity FK、original audience／Apple `client_id`、credential generation、暗号化refresh token、vault key version、state、last validated／revoke state | 平文token、Apple private keyをDBへ置かず、別audienceのgrantを上書きしない |
| `auth_attempts` | mode、state／nonce hash、provider-required PKCE challenge／暗号化verifier、client platform、`claimed → providerCallStarted → providerResultKnown → terminal` phase／lease、期限、暗号化provider result／短期session grant／receipt | identity token／authorization codeをterminal後も保持しない。v1独自のdevice identity／PoPを作らない |
| `auth_sessions` | Account／identity、opaque session family ID、client platform、fence generation、state、auth／expiry時刻 | provider access tokenをsync sessionとして使わず、端末識別子やhardware fingerprintをidentityにしない |
| `session_token_families` | refresh token HMAC、generation、rotation／reuse state、期限 | refresh token平文を保存しない |
| `session_refresh_receipts` | refresh operation ID、family／generation、request digest、短期暗号化response、期限 | exact lost-response retry以外へtokenを再表示しない |
| `provider_notification_receipts` | provider、JTIまたはpayload digest、event type、処理時刻 | notification生payload、emailをaudit目的で保存しない |
| `auth_events` | link／revoke／session／fenceのtype、opaque ID、時刻、request ID | token、subject、原稿、title、path、emailを記録しない |

`subject_lookup_v1`はKMS由来の独立した256-bit以上のlookup keyによる **HMAC-SHA-256の全32 bytes** とする。入力はASCII domain label `FUMINIWA-EXTERNAL-IDENTITY-LOOKUP-V1`に続けて、`providerConfigID`、検証済みexact issuer、検証済みsubjectの各UTF-8 bytesを **4-byte unsigned big-endian byte length + bytes** で順に連結する。Unicode正規化、区切り文字連結、digest切り詰めを行わない。PostgreSQLは32-byte `bytea`として保存し、base64url／hexはfixture／診断表示だけに使う。lookup key versionとdigestへunique制約を置き、同じ外部identityを2 Accountへ結び付けない。

lookup key rotationは、旧versionをlookup可能なまま、新keyをactive-writeにする前にauth-vault ciphertextを監査付きで復号して新HMACをbackfillし、旧／新digest両方のunique検査と件数・AccountID mapping照合を完了する。sign-in中のlookupはrotation ledgerが示す全active-read versionを検索し、見つからない場合も同じencrypted canonical identityの重複をtransaction内で再検査してからだけAccountを作る。全rowのread-backとrollback世代を確認するまで旧lookup keyを廃棄しない。ciphertext／lookup key／provider credentialは別key domainとし、auth-vault role以外へ復号権限を与えない。

`external_identity_secrets`と`provider_credentials`のciphertext envelope v1はAES-256-GCM、rowごとのrandom 256-bit DEK、96-bit random nonce、128-bit tagを使い、DEKをKMS KEK versionでwrapする。AADはASCII domain label、table purpose、opaque row ID、providerConfigID、credentialならoriginal audience/client_idを4-byte big-endian length-prefixで連結し、row移植／purpose混同を拒否する。KEK rotationはplaintextを再保存せずDEKだけをunwrap／rewrapし、DEK compromise rotationはrow lock下で新DEK／nonceへ再暗号化・decrypt read-backしてから新envelopeをcommitする。rotation ledgerをrow単位で冪等化し、kill/restart時も旧／新envelopeのどちらか一方をcurrentとして再開する。旧KEK／DEKは参照row 0、全row digest／decrypt read-back、rollback window終了、対象backupの再wrapまたはretention終了、別環境restore drillが揃うまで廃棄しない。vault key rotationだけでAccountID、credential generation state、session、AccountAuthEpoch／Fenceを変えない。

次のtransactionはall-or-nothingにする。

1. 初回sign-in: verified identity lookup、既存Account復帰またはAccount＋Tenant＋identity作成、session／refresh family発行。
2. refresh: active sessionとcurrent fence検査、旧refresh token consume、新token発行、refresh receipt保存。同じoperation ID＋request digestのlost-response retryだけは同じ暗号化responseを返し、別operation IDで消費済みtokenが再利用された場合は該当familyだけを`reuseDetected`へ進める。AccountAuthEpoch／Fenceと別session familyは変えない。
3. revocation: identity／credential失効、対象session失効、fence rotate、notification receipt、auth event。
4. 将来link／unlink: 両identity検査、identity FK変更、session失効、fence rotate、auth event。v1 routeからは呼べない。

Apple code exchangeは`providerCallStarted`を最初のnetwork byteより前にcommitする。`claimed`のままleaseが切れたattemptだけは再開して1回目のprovider callへ進める。`providerCallStarted`でresult未耐久のattemptはcodeを再送せず、再起動後にreceipted `providerExchangeIndeterminate`へ収束する。Apple成功responseはauth-vaultへ`providerResultKnown`としてenvelope-encryptしてからAccount／credential／session／terminal receipt transactionへ進み、ここでkillされてもAppleを呼び直さず再開する。

Apple provider credentialは同じexternal identityでもoriginal authorization audience／`client_id`ごとに別grantとして所有する。Mac audienceとiOS／iPadOS audienceは同じAccountIDへ収束しても、`(external identity, audience, credential generation)`を別rowにする。再認証で同じaudienceの新refresh tokenを得た場合は、新generationを暗号化・read-backしてactiveへした後だけ旧generationをsupersedeし、別audienceのactive grantを変えない。consent revoke／account deletionは全active／superseded-but-not-revoked credentialを列挙し、それぞれ元のauthorization requestと一致する`client_id`でApple revokeを行う。一部失敗はAccount削除完了へ読み替えずdurable retryに残し、各credentialのApple revoke receiptをread-backできるまでremote削除完了にしない。

## 6. Swift client moduleと保存境界

```text
NovelAuthDomain
  AuthProviderDescriptor / AuthAttempt / AuthState / AuthenticatedBinding / error
       ↑                ↑                 ↑
NovelAuthApple     NovelAuthHTTP     NovelAuthKeychain
AuthenticationServices  URLSession       Keychain actor
       └────────────── AuthFeature ──────────────┘
                              ↓
                         SyncFeature
```

- `NovelAuthDomain`はFoundation値型とprotocolだけにし、AuthenticationServices、URLSession、Security、GRDB、UI frameworkへ依存しない。
- `NovelAuthApple`だけが`ASAuthorizationAppleIDProvider`、credential state、revocation notificationを扱う。
- `NovelAuthHTTP`はauth attempt、exchange、FUMINIWA refresh／logout、capabilitiesだけを扱い、SQLiteへ直接触れない。token-bearing responseはephemeral URLSession configurationで受け、HTTP `Cache-Control: no-store`／`Pragma: no-cache`を必須検査し、URLCache／disk cacheへ保存しない。
- `NovelAuthKeychain` actorはFUMINIWA access／refresh token、opaque session IDに加え、server検証済みexchangeへ対応する`ASAuthorizationAppleIDCredential.user`をproviderConfig単位の **Apple credential-state専用opaque handle** として保存できる。このhandleは`getCredentialState(forUserID:)`にだけ使い、AccountID、account link、sync requestへ使わない。v1は独自installation key／device PoP／hardware fingerprintを設けない。Apple refresh tokenとclient secretはserverだけが保持し、v1にwork keyは存在しない。原稿、email、authorization code、identity tokenをKeychainへ保存せず、credential-state handleをSQLite、`.novelpkg`、UserDefaults、log、crash reportへ出さない。
- KeychainのFUMINIWA token pairはsession familyの`refreshGeneration`を含む。refresh responseは「送信に使ったrefresh tokenとそのgenerationがまだcurrentで、response generationが直後である」場合だけactor内compare-and-swapで置換する。後続rotation／sign-out／account switch後に届いた古いexact-replay responseはmemoryから破棄し、Keychainを巻き戻さない。
- Apple identity token、authorization code、raw nonce／stateと未検証のApple user handleはexchange完了までのmemoryだけに置く。server exchange成功後だけ対応するuser handleをcredential-state用Keychain itemへcommitし、terminal failureではすべて破棄する。
- SQLiteは`AuthenticatedBinding(server instance, protocol epoch, AccountID, account fence)`の非秘密snapshot、workの`unbound／bound／quarantined`、network park理由だけを持つ。credentialをSQLite、`.novelpkg`、UserDefaults、log、crash reportへ書かない。
- Keychain読込不能／token expiryでも空accountへfallbackせず、最後のbindingを表示用に保持してlocal editを続ける。新credentialを検証するまでuploadしない。

## 7. Sign-in、Session、Linking

### 7.1 Apple sign-in v1

ProductionではmacOS App IDとiOS／iPadOS App IDを同じSign in with Apple primary App IDへgroupし、各bundle IDを同じ`providerConfigID`の許可audienceとしてserverへ明示登録する。将来web／Windows flowを加える場合もServices IDを同じprimary App IDへ関連付ける。Apple設定、Team、audienceが違うsubjectを返した場合にemail一致で補修せず、paired Mac／iPhoneが同じAccountIDをread-backできるまでRelease NO-GOとする。

1. clientはserverから短寿命auth attempt、state、nonceを取得する。v1は氏名／email scopeを要求しない。
2. `NovelAuthApple`がstate／nonceをApple requestへbindし、返ったauthorization codeとidentity tokenをTLSでserverへ渡す。
3. serverのApple adapterが署名、issuer、audience、nonce、期限を検証し、authorization codeをApple serverで交換する。
4. application serviceがverified issuer／subjectをlookupし、同じidentityなら同じAccountID、新規なら1 transactionでAccountを作る。
5. token exchangeで得たApple refresh tokenはchallengeにserverが固定したoriginal audience／client_idのcredential generationとして暗号化し、同audienceの旧generationだけを安全に置換する。
6. serverはApple tokenではなくFUMINIWA sessionを返す。clientはKeychainへcommit後、capabilitiesでAccountID／fenceをread-backする。
7. clientはread-backとSQLite binding installを完了するまでworkerを開始しない。response lossはauth attemptへ短期暗号化保存した同じsession grantから回復し、別Account／refresh familyを作らない。

### 7.2 Provider-neutral explicit link policy

tableとdomainは複数identityを許すが、v1ではlink／unlink UIとHTTP APIを公開しない。将来追加する場合も次を変更しない。

- login中のactive session、現在のidentityへのfresh reauthentication、新providerのone-time link attemptをすべて要求する。
- email、氏名、Apple private relay address、同じ端末、同じIPを根拠にautomatic linkしない。
- 新identityが同じAccountIDに既に属すればidempotent success、別AccountIDに属すれば存在を漏らさないtyped conflictとし、automatic mergeしない。
- unlinkは別のactive identityまたは明示的なrecovery手段がある場合だけ許す。最後のlogin手段を消さない。
- link／unlink後もAccountID／Tenant／WorkIDは不変。全sessionを再認証へ送り、account fenceをrotateする。
- Account mergeはv1 scope外。別Accountへ作品を移す場合は明示Export／Importまたはnew WorkID cloneを使う。

## 8. Apple検証と失効

Apple adapterはApple公式の[Authenticating users with Sign in with Apple](https://developer.apple.com/documentation/signinwithapple/authenticating-users-with-sign-in-with-apple)と[Verifying a user](https://developer.apple.com/documentation/signinwithapple/verifying-a-user)に従う。

- Apple issuerと許可audienceをserver configへ固定し、client入力で変えない。
- state、nonce、authorization codeの一回性、JWT signature、`iss`、`aud`、`exp`／`iat`を検証する。email claimはidentity根拠にしない。
- Apple JWKSは[Apple公式key endpoint](https://developer.apple.com/documentation/signinwithapplerestapi/fetch-apple%27s-public-key-for-verifying-token-signature)からTLSで取得し、`kid` rotationを許す。未知key時だけbounded refreshし、取得失敗時に署名検証をskipしない。
- Apple client secret署名鍵はProduction secret manager／KMSへ置き、repository、image、PostgreSQL、client、logへ出さない。
- Apple refresh tokenはoriginal audience／client_idごとにserver credential vaultへ暗号化保存し、clientへ返さない。明示unlink／FUMINIWA account削除ではApple公式の[Token revocation](https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens)を、各grantを発行したclient_idで呼ぶ。一部失敗はdurable retry／運用alertへ残し、全grantのrevoke receiptが揃うまでremote削除完了を返さない。
- activeなApple credentialはApple公式TN3194の範囲内で最大1日1回までrefresh token validationを行い、日常のFUMINIWA token refreshごとにAppleへ問い合わせない。

server-to-server endpointは[versioned Apple notification contract](auth/v1/apple-notification.md)と[Processing changes for Sign in with Apple accounts](https://developer.apple.com/documentation/signinwithapple/processing-changes-for-sign-in-with-apple-accounts)に従い、JWS signature、`iss`、`aud`、`iat`、`jti`、event subjectを検証する。receiptとstate mutationを同じtransactionへdurable化してから2xxを返し、同じJTI／digestを何度受けても1回だけ処理する。unknown subjectからAccountを作らず、再認証後に遅れて届いた古いeventは新credentialを即時失効せずprovider validationへparkする。

| Apple event | server処理 |
| --- | --- |
| `email-enabled / email-disabled` | receiptだけを記録する。emailを保存せず、AccountID／session／fenceを変えない |
| `consent-revoked` | identityを`revoked`、provider credentialを失効／消去、全sessionを`reauthRequired`または`revoked`、fence rotate。原稿は削除しない |
| `account-deleted` | identityを`providerDeleted`、credential／session失効、fence rotate。別identityがあればAccountは維持し、唯一のidentityならAccountを`locked`にして明示的な回復／削除policyへ渡す |

Apple clientは`ASAuthorizationAppleIDProviderCredentialRevokedNotification`を購読し、foreground／通知時にcredential stateを確認する。client通知だけをserver削除の証拠にせず、server通知と次回API authenticationも独立authorityにする。Appleの[TN3194](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple)に従い、失効時はnetworkをsign-out／reauthへ移すが、端末内原稿を削除しない。

## 9. Security、PII、server-readable境界

- 全auth／sync trafficはTLS必須。redirect、callback、notification URLもHTTPS固定とする。
- 将来OIDCを追加してもprovider configは運用者allowlistだけから読み、client指定issuer／JWKS／token endpointをfetchしない。Discovery結果のissuer exact一致とHTTPSをfail-closedで検査する。
- FUMINIWA access tokenは短寿命opaque乱数、refresh tokenは高entropy乱数＋一回rotationとする。DBはtoken HMACだけを持ち、平文はclient Keychainだけに置く。正確な寿命はR0 auth wireで固定する。
- provider refresh tokenだけは失効／再検証のためserver vaultへ暗号化保存する。DB backup、key backup、rotation、復号auditをR8 Gateへ含める。
- raw provider subject、email、name、identity token、authorization code、access／refresh token、Apple notification payloadをanalytics、structured log、trace、error bodyへ出さない。
- auth eventはopaque ID、event class、時刻、request IDだけを持つ。IP／device labelの長期保持は別の明示Decisionなしに追加しない。
- auth schema／DB roleとsync content schema／object-store roleを分離し、provider adapterへSnapshot、ObjectID、WorkID、title、本文のread権限を与えない。
- `serverReadableV1`では同期server運用者が技術的に原稿payloadを読める。Sign in with Appleは本人確認であって暗号化や鍵回復ではない。この運用境界を利用者へ明示し、E2EEを後付け可能なauth toggleとして表現しない。
- external providerへAccountID、Tenant ID、WorkID、ObjectID、原稿、path、同期状態を送らない。

### 9.1 利用者へ出す認証UI

- 初回のオンライン保存設定と再認証にはApple標準のSign in with Apple buttonだけを出し、provider picker、email／password form、未実装provider、AccountIDを表示しない。
- 通常の作品棚とeditorは認証画面を経由せずlocalから開く。access token expiryは小さな「ログインが必要」状態に留め、modalで執筆、autosave、遷移、closeを塞がない。
- sign-outの文言は「オンライン保存からサインアウト」とし、端末内原稿を削除する操作に見せない。アカウント削除とは別操作であることを明示する。
- 同じAccountIDへ戻った場合は送信を安全に再開する。別AccountIDなら「別のオンラインアカウントです」とだけ示し、旧accountの作品名／存在を新account側へ漏らさず、明示Export／Import以外で移さない。
- `serverReadableV1`の説明は初回オンライン保存の確認とprivacy説明から到達できるようにし、「Appleでサインイン」だけで運用者にも読めないと誤認させない。

## 10. GateとLuna実装順

### R0 Auth Contract Gate

- Apple-only v1、4層境界、AccountID不変、state／transition、fence rotation、typed auth error、auth endpoint request／responseをdesign fixtureへ固定する。
- 同時初回login、Apple exchange各durable phaseのprocess kill、lost response、nonce／issuer／audience／signature失敗、refresh exact replay／別operation reuse／古いresponse、notification duplicate／unknown subject／再認証との順序、consent revoke、Mac／iOS grant別client_id revokeと部分失敗、account switch、same AccountID＋new fence、different AccountID、auth↔sync binding一致、offline継続をfixture化する。
- provider linkingはpolicy fixtureだけを置き、v1 OpenAPI route／feature flag／UIを追加しない。
- Appleが唯一のidentityだった場合のrecoveryと、`account-deleted`／利用者のアプリ内削除要求後のremote data保持／削除期間を後続Product Decisionにする。これはApp Store提出前のRelease blockerであり、`locked`のまま永久保管する設計ではGOにしない。

### R4 Rust Auth Gate

- migration unique／FK／state constraint、同時identity作成、session rotation、fence atomicity、Mac／iOS audience別credential generationとrevoke retryをPostgreSQL integration testで通す。
- Apple signed-token fixture、JWKS rotation、wrong nonce／issuer／audience、code replay、notification idempotencyを通す。macOS／iOSのallowlisted audienceが同じproviderConfigIDとAccountIDへ収束し、未登録audienceがAccount存在情報を得られないことを確認する。
- Production configurationでdev tokenを受理できず、auth adapterがsync contentを読めないことをdependency／DB-role auditで確認する。

### R5 Swift Auth Gate

- Mac／iPhoneでKeychain commit、restart、token refresh、古いrefresh responseの世代CAS拒否、HTTP cache非保存、revocation notification、credential-state handle／変更、account switchを実機検証する。
- auth失敗中もeditor、autosave、遷移、close、quitがremoteを待たず、旧scopeへ1 byteも送らないことを確認する。
- AccountID／fence read-back前のworker開始、別Accountへのautomatic adopt、tokenのSQLite／log混入を機械検査する。

### R8 Production Gate

- Apple Production configuration、macOS／iOS App IDのprimary grouping、lookup HMAC keyとauth-vault KEK／DEKのkill-resumable rotation／旧鍵廃棄、server-to-server notification、token revoke、backupからのcredential／fence整合復旧を実環境で確認する。
- TLS、rate limit、brute-force／replay防止、token／PII log scan、DB role、incident時の全session revoke＋fence rotationをsecurity reviewする。
- recovery／アプリ内account deletion開始導線、Apple token revoke、remote data削除完了のread-back、server-readable disclosure、署名済みMac＋iPhoneの失効／再認証を通すまでProduction GOにしない。

Lunaには次の順で、各段階を別PRとして依頼する。

1. **R0文書／fixtureのみ**: auth state、request／response、Apple claim fixture、fence／account-switch scenarioをfreezeする。コードを書かない。
2. **Rust pure domain＋migration**: provider-neutral state／port、table／constraint、transaction test。network adapterはまだ入れない。
3. **Apple adapter**: code exchange、JWT／JWKS、credential vault、typed failure。同期routeへ直結しない。
4. **FUMINIWA session＋fence**: opaque token、refresh rotation、capabilities、Axum principal middleware。
5. **Apple notification／revoke**: idempotent receipt、revocation transaction、fence rotation、operator recovery。
6. **Swift auth**: `NovelAuthDomain`→Keychain／HTTP→Apple adapter→App compositionの順。UIより先にaccount-switch／offline fixtureを通す。
7. **Integration／Production hardening**: real signed devices、lost response、restart、notification duplicate、backup restore、security audit。

将来OIDC adapterやlink UI／APIはApple-only v1の合格後に別Decision／PRで追加し、既存AccountIDを作り直さない。
