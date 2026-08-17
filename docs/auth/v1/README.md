# FUMINIWA Auth wire v1 — R0 design contract

このdirectoryはD-078で確定したSnapshot Sync用認証の **実装前wire契約** である。Rust auth server、Sign in with Apple adapter、Keychain client、Production deploymentが実装済みであることを示さない。HTTPの正は[`openapi.yaml`](openapi.yaml)、状態遷移のcross-language acceptanceは[`fixtures/`](fixtures/)である。

`authProtocolEpoch=1`／`authProtocolVersion=1.0.0`はAuth protocol v1の値として維持する。現在のlive SyncはD-080の新namespaceでprotocol epoch `2`なので、capabilitiesとすべてのsession bindingの`syncProtocolEpoch`は`2`である。これはAuth epochとは別の値であり、Auth implementationはSync v2の`PROTOCOL_EPOCH`をbindingへ注入する。AccountFenceのbindingもserver instance＋Sync epoch `2`＋AccountID＋AccountAuthEpochで評価する。

## 固定する境界

- Production v1の外部identity providerは`apple`、flowはAuthenticationServicesを使う`native`だけである。macOS／iOS／iPadOS clientはprovider選択UI、web redirect、別provider adapterを実装しない。Apple primary App ID groupingは同じ`providerConfigurationId=apple-primary-fuminiwa-v1`とし、server側audience allowlistをMacの`dev.serikayuzuki.fuminiwa`、iOS／iPadOSの`dev.serikayuzuki.fuminiwa.ios`だけに閉じる。request bodyのaudienceを信用しない。
- wireはprovider discriminatorを持つが、v1 schemaが受理する値は`apple`だけである。将来providerを増やす場合もprovider adapterの出力を`VerifiedExternalIdentity`へ畳み、opaqueなFUMINIWA `AccountID`、1 Account＝1 Tenant、Snapshot Sync wireを変更しない。別providerをunknown stringとしてv1へ通さない。
- Apple authorization code、identity token、server-side Apple refresh tokenをSnapshot Syncへ渡さない。同期APIのBearerはFUMINIWA auth serverが発行した短命・opaqueなaccess tokenだけである。
- v1 content protectionは`serverReadableV1`、`e2ee=false`で確定している。TLSとserver管理の保存時暗号化を必須とするが、権限を持つserver運用者と復旧backupから原稿を読める。E2EEはv1 capability toggleではなく、将来の別protocol namespace／epochと非互換migrationでのみ設計できる。
- Appleのemail、氏名、private relay addressは要求せず、返却されてもidentity、dedupe、account link、recovery、profile authorityに使わない。verifiedな`(provider configuration, exact issuer, subject)`だけをexternal identity keyとし、同じemailでも別subjectを自動linkしない。

## Native flow

1. clientはpublic `GET /v1/auth/capabilities`を読み、`provider=apple`／`flow=native`、client platformに対するserver選択済みaudience、TTLを確認する。
2. clientはreceipt-idempotentな`POST /v1/auth/challenges`を送り、server生成の独立した256-bit `state`／`nonce`を受け取る。両値はsingle-useで、clientはそのままAuthenticationServices requestへ設定する。scopeは空配列で固定する。
3. Apple成功時に限り、clientは同じchallengeの`state`、短命single-use authorization code、identity tokenを`POST /v1/auth/challenges/{challengeId}:exchange`へ一度だけ渡す。名前、email、Apple user identifierを別fieldとして送らない。
4. serverは同operation receiptをchallenge lifecycleより先に照会する。新規attemptならchallengeをatomicにclaimし、state、Apple JWS signature／matching `kid`、exact issuer、configured audience、expiry／issued-at、nonce、subjectを検証する。続けてApple token endpointでauthorization codeを交換し、返却されたidentity tokenのissuer／audience／subjectを検証して最初のtokenと同一identityであることを確認する。
5. 全検証成功後だけexternal identityをAccountIDへlookup／createし、session、FUMINIWA token pair、encrypted replay receiptを同じtransactionへ確定する。clientはtoken pairをKeychainだけへ保存し、SQLite、`.novelpkg`、logへ書かない。

Apple authorization codeはsingle-useかつ5分だけ有効であるため、challenge TTLも300秒である。serverがAppleへrequestを送った後に結果を確定できない場合は同じcodeをblind retryせず、terminal `providerExchangeIndeterminate/restartAuthentication`とする。response loss後のexact replayだけは保存済みreceiptから同じFUMINIWA token pairを返し、Apple codeを再交換しない。

Apple JWS検証は固定issuer、server設定済みaudience、Apple JWKSのmatching `kid`、server側algorithm allowlistを使い、`none`／unknown algorithmを拒否する。ambient key cacheだけをauthorityにせず、unknown `kid`ではApple JWKSをbounded refreshしてから一度だけ再評価する。Apple credential、token payload、subject、code、state、nonceはlogへ出さない。

## Session rotation and replay

- access tokenは短命、refresh tokenはopaqueかつone-time rotationである。どちらもApple tokenではなくclientからparseしない。
- refreshは`rotationId`をidempotency keyとする。同じsession family＋提示済みrefresh token＋同じrotation ID＋exact JCS bodyは、active-token検査より先にencrypted rotation receiptを読み、同じtoken pairを返す。
- token pairはsession family内の単調増加`refreshGeneration`を必ず返す。clientは提示token＋旧generationがまだKeychainのcurrentで、responseが直後のgenerationである場合だけactor内CASで置換する。後続rotation、sign-out、account switch後に届いた古いexact responseは破棄し、Keychainを過去のtokenへ戻さない。
- 消費済みrefresh tokenを別rotation IDで再利用した場合は`refreshTokenReused`としてsession familyを失効し、interactive Apple sign-inを要求する。serverはそれを通常network retryへ読み替えない。
- current-session revokeは同operation receiptをsession active判定より先に読み、lost ACKで同じ結果を返す。これはFUMINIWA sessionのsign-outであり、Apple consent revoke、provider token revoke、remote account／work deletionではない。
- Apple provider refresh tokenはserverだけがenvelope encryptionして保持し、Apple policyに従うcredential-state validationとserver-to-server notification処理に使う。clientへ返さない。同じexternal identityでもMacとiOS／iPadOSのoriginal audience／client_idごとにcredential generationを分け、reauthで別audienceのgrantを上書きしない。Apple revokeは各grantを発行したclient_idで行い、一部失敗はdurable retryして全grantのreceiptが揃うまでaccount削除完了にしない。provider notification endpointはAppleからserverへの別versioned境界であり、[`apple-notification.md`](apple-notification.md)を正とする。

## Account mapping and fence

auth adapterがcoreへ渡す値は内部の`VerifiedExternalIdentity { providerConfiguration, issuer, subject }`だけである。最初のverified identityは新しいopaque AccountIDを作り、同じkeyへの再認証は常に同じAccountIDへ戻る。同じemail、氏名、relay address、異なるApple subjectを自動mergeしない。v1にidentity link／unlink APIはない。

identity lookupはdomain-separated／4-byte big-endian length-prefixed canonical bytesのversion付きHMACを使う。HMACは不可逆なので、providerConfig／issuer／subject canonical bytesはauth-vaultだけへenvelope-encryptして保持し、lookup-key rotation時に監査付きで復号・再HMACする。通常table、index、logにはsubject平文を置かず、旧／新keyのdual-readと全mapping read-backが終わるまで旧keyを廃棄しない。

`AccountFence`はtoken個体ではなく、`serverInstanceId + sync protocol epoch + AccountID + AccountAuthEpoch`へbindしたopaque値である。access／refresh token rotation、current-session revoke、同一Apple identityへの再認証では変えない。identity／security scope変更、全session失効、Apple consent revoke等ではserverがAccountAuthEpochを単調増加させ、fenceを変える。clientは同じAccountIDでも旧fenceのcursor、object presence、Intent、SealedAttemptを送らずquarantineし、authenticated sync capabilitiesとfull bootstrapから再計画する。別AccountIDへloginしただけでlocal workをadoptしない。

利用者によるserver account削除、remote payload retention、Apple token revoke、再認証、完了read-backを含むlifecycle APIはauth wire v1のscope外である。ただしaccount creationをApp Store版へ出す前に、Appleの[Offering account deletion in your app](https://developer.apple.com/support/offering-account-deletion-in-your-app/)と最新Review Guidelinesに適合するapp内account deletion UI／API、監査済みretention／revoke動作を別Decision・versioned contract・fixtureとして完成させることを **App Store Release blocker** とする。scope外であることを、削除導線なしで出荷してよい根拠にしない。

## Exact JCS and receipts

JSON request／responseは`application/vnd.fuminiwa.auth.v1+jcs`のexact UTF-8 RFC 8785 JCSである。closed schema、lowercase UUID、unsafe integer禁止、unknown member拒否を共通とする。serverはaccepted canonical command bytesのSHA-256を計算し、client supplied digestを信用しない。

全`operationId`／`rotationId`はserver-instance-global registryでcommand kindを跨いで一意とし、別kindへの再利用をfail-closedにする。そのうえでauth receiptのstate lookup scopeを次の通り固定する。TLS／media／closed-schema検査とscope特定後、既存receipt lookupはactive／consumed判定と新規commandへのrate limitより先に行う。

| command | receipt scope | replay lookup order |
| --- | --- | --- |
| challenge create | server instance＋operation ID＋kind | operation reuse検査後、challenge生成前 |
| Apple exchange | challenge ID＋operation ID＋kind | consumed／expired検査前 |
| refresh | session family＋presented token verifier＋rotation ID | refresh token active／consumed検査前 |
| current-session revoke | session family＋operation ID＋kind | session active／revoked検査前 |

token pairを返すreceiptはexact replayに必要なcanonical response bytesをserver-side keyでenvelope-encryptして耐久化する。token verifierはhash／HMACだけを通常tableへ持ち、生token、decrypted receipt、Authorization headerをDB列、trace、metrics、errorへ出さない。receipt期限後は古いApple codeやrefresh tokenを再実行せずinteractive sign-inへ戻る。

exchange／refreshのtoken-bearing responseは`Cache-Control: no-store`と`Pragma: no-cache`を必須とする。clientはephemeral URL loading sessionを使い、responseをURLCache／disk cacheへ保存しない。header欠落はtokenをKeychainへ採用せずsecurity failureとして扱う。

## Fixture

[`fixtures/`](fixtures/)は実装言語に依存しないstate-machine inputである。`providerScript`はnetworkを使わないfake Apple adapterの順序付き結果、`steps[].request.body`／`expect.body`はwire body、`expectState`はtransaction後の抽象server stateである。代表commandの`expectedCanonicalBodyUtf8`／byte count／SHA-256は各実装が独立に一致させる。`sameCanonicalResponseAsStep`はstatusとexact canonical response bytesが指定stepと一致し、provider callとmutationが増えないことを意味する。`symbols`の値はfixture専用で、実token／credentialではない。

- [`apple-native-exchange.json`](fixtures/apple-native-exchange.json): state／nonce／code validation、AccountID mapping、exchange lost ACK
- [`apple-exchange-crash.json`](fixtures/apple-exchange-crash.json): challenge claimからApple call／result／receiptまでのprocess-kill収束
- [`concurrent-first-login.json`](fixtures/concurrent-first-login.json): 同じApple identityの同時初回loginが1 AccountIDへ収束
- [`refresh-rotation.json`](fixtures/refresh-rotation.json): one-time rotation、exact replay、reuse family revoke
- [`session-fence.json`](fixtures/session-fence.json): current-session revoke後のlocal編集継続、same-identity reauthentication、AccountAuthEpoch fence rotation、different Apple subjectの別Account化とautomatic adopt禁止
- [`auth-sync-binding.json`](fixtures/auth-sync-binding.json): Auth `/me`とSync capabilitiesのAccountID／epoch／Fence一致
- [`identity-lookup-key-rotation.json`](fixtures/identity-lookup-key-rotation.json): encrypted identityからの監査付きHMAC再計算、dual-read、kill/restart
- [`vault-key-rotation.json`](fixtures/vault-key-rotation.json): identity／provider credential envelopeのKEK／DEK rotation、backup、Fence不変
- [`apple-server-notification.json`](fixtures/apple-server-notification.json): signed notification、JTI idempotency、unknown subject、stale ordering
- [`apple-multi-audience-revoke.json`](fixtures/apple-multi-audience-revoke.json): Mac／iOS grant別client_id、部分失敗、同operation retry、削除未完了fence

## Apple primary contract

実装とsecurity reviewは少なくとも次のApple一次資料をliveで再確認する。

- [Authenticating users with Sign in with Apple](https://developer.apple.com/documentation/signinwithapple/authenticating-users-with-sign-in-with-apple)
- [Verifying a user](https://developer.apple.com/documentation/signinwithapple/verifying-a-user)
- [Generate and validate tokens](https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens)
- [Request an authorization](https://developer.apple.com/documentation/signinwithapplerestapi/request-an-authorization-to-the-sign-in-with-apple-server)
- [Fetch Apple public keys](https://developer.apple.com/documentation/signinwithapplerestapi/fetch-apple%27s-public-key-for-verifying-token-signature)
- [Processing account changes](https://developer.apple.com/documentation/signinwithapple/processing-changes-for-sign-in-with-apple-accounts)

## Static validation

```sh
ruby -e 'require "yaml"; YAML.safe_load(File.read("docs/auth/v1/openapi.yaml"), aliases: true); puts "auth openapi yaml ok"'
find docs/auth/v1 -name '*.json' -print0 | xargs -0 -n1 jq -e .
git diff --check
```

これだけではApple live conformance、JWS／JWKS rotation、JCS byte equality、Keychain、encrypted receipt、rate limit、cross-tenant non-disclosure、server notification、offline editingを証明しない。R0 runnerはfixtureの全step、OpenAPI `$ref`、duplicate `operationId`、closed schema、exact replay side-effect countを検査する。
