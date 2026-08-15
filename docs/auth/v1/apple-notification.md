# Sign in with Apple server notification contract v1

> **状態**: D-078 R0のprovider ingress契約。client向け[`openapi.yaml`](openapi.yaml)とは別のApple→Rust server境界であり、実装済みを示さない。

## HTTP境界

- endpointは`POST /v1/auth/providers/apple/notifications`、TLS 1.2以上、`Content-Type: application/json`、body上限64 KiBとする。
- Apple公式bodyの唯一のmember `payload`にcompact JWSを受ける。未知member、duplicate key、空payload、上限超過をprovider callやidentity lookup前に拒否する。
- 成功はbodyなし`204`。署名／claim／shape不正はaccount存在を示さない同一のbodyなし`400`または`401`、receipt／state transactionを耐久化できない場合はbodyなし`503`としてAppleの再送へ委ねる。
- raw body、JWS、header、claim、subject、email、JTIをapplication log、trace、analytics、error bodyへ出さない。request IDとgeneric outcome classだけを記録する。

## JWS検証

Appleの[Processing changes for Sign in with Apple accounts](https://developer.apple.com/documentation/signinwithapple/processing-changes-for-sign-in-with-apple-accounts)どおり、`payload`はApple署名付きJWSとして検証する。v1は次をすべて満たさなければstateを変更しない。

1. compact JWSは3 segment、headerは`alg=RS256`かつnonempty `kid`。`none`、unknown algorithm、embedded key／URLを拒否する。Appleがalgorithmを変更した場合はallowlistとfixtureを更新するまで受理しない。
2. `kid`でApple公式JWKSを選び、未知`kid`だけbounded refreshして一度再評価する。TLS／JWKS失敗時に署名検証をskipしない。
3. `iss`はexact `https://appleid.apple.com`、`aud`はserver設定済みApple audience allowlistのいずれか、`iat`はJSON safe integerかつserver時刻より許容clock skewを超えて未来でない、`jti`はnonempty bounded stringである。
4. `events`はobjectで、`type`は`email-enabled`、`email-disabled`、`consent-revoked`、`account-deleted`のいずれか、`sub`はnonempty bounded string、`event_time`はJSON safe integerである。email eventに含まれる`email`／`is_private_email`はidentityやprofileへ保存しない。
5. verified subjectはactive-read lookup key versionすべてでHMAC lookupし、処理後にmemoryから破棄する。unknown subjectからAccount／Tenant／identityを作らない。

## Receiptと順序

receipt identityは`providerConfigID + jti`、comparison digestは受理したraw compact JWS bytesのSHA-256とする。同じJTI＋同じdigestはstate mutationを増やさず同じ`204`を返す。同じJTI＋異なるdigestはsecurity alertを耐久化してgeneric rejectionとし、どちらのpayloadも再適用しない。

JWS検証後、identity rowをlockし、`provider_notification_receipts`、identity／credential／session／AccountAuthEpoch変更、auth eventを1 PostgreSQL transactionで確定してから`204`を返す。process kill前にcommitしていなければApple retry、commit後のresponse lossならduplicate receiptから副作用0の`204`へ収束する。

- `email-enabled`／`email-disabled`: receiptだけ。emailを保存せずAccount、session、Fenceを変えない。
- `consent-revoked`: 対象identityの全audience credential generationをrevoke／validation対象にし、対象Accountの全sessionを失効、AccountAuthEpoch／Fenceを1回だけ進める。原稿は削除しない。
- `account-deleted`: 同じ失効／Fence transitionに加え、別active identityがあればAccountを維持し、唯一なら`locked/deletionPending`へ進める。通知だけでremote原稿をhard-deleteしない。
- unknown subject: `unknownIdentity` receiptだけを残し、Account作成、Fence変更、存在を示すresponseを行わない。

notification `event_time`より後に同じidentityの検証済みsign-inが既にcommit済みなら、古い通知で新credential／sessionを巻き戻さない。receiptを`staleAfterReauthentication`として保存し、remote laneを`providerValidationPending`へparkしてserver-side credential validationを行う。Appleがcredentialをvalidと検証した場合はAccountAuthEpoch／Fenceを変えず再開する。`invalid_grant`または署名付きprovider stateがrevoked／notFoundを示す **authoritative invalid** だけが上記revoke transitionを1回適用できる。timeout、DNS、TLS、rate limit、Apple 5xx、応答decode不能は`transientIndeterminate`としてdurable retryし、新credential、session、AccountAuthEpoch／Fenceを変えない。認証が止まっても端末内open／edit／autosave／history／Exportは止めない。

## Acceptance fixture

[`fixtures/apple-server-notification.json`](fixtures/apple-server-notification.json)をRust adapter／PostgreSQL transactionで共用する。`scenarios[].request.body.payload`を持つcaseはfixture JWKで実compact JWSを検証するwire vector、`layer=postVerificationDomainEvent`はその検証済み出力だけをidentity／ordering state machineへ渡すdomain vectorであり、placeholder JWSをwireへ送らない。署名bytesはfixture専用test keyで生成し、Production Apple keyとして扱わない。R4ではApple live JWKS rotationとProduction configurationも別途確認する。
