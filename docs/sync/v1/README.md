# Snapshot Sync wire v1 — reviewed R0 design contract

このdirectoryは、最終設計監査を通過したFUMINIWA Snapshot Syncの **実装用設計契約** である。Rust server、SQLite client、CloudKit migration、Sign in with Apple、`192.168.11.5`への配置が存在することを示すものではない。D-078でcontent protectionとProduction external identityは確定しているが、Swift／Rust／将来C#の独立conformance runnerとRelease Gateが終わるまでR0実装合格やProduction互換を宣言しない。

protocol v1は`contentProtectionProfile=serverReadableV1`、`e2ee=false`で確定している。TLSとserver管理の保存時暗号化を必須とするが、権限を持つserver運用者と復旧backupから原稿を読める。E2EEをv1のflagとして追加せず、必要になった場合は暗号化object identity、鍵envelope、server validation／reconciliation境界を別namespace／epochの非互換migrationとして置き換える。

Production同期Bearerは[`../../auth/v1/openapi.yaml`](../../auth/v1/openapi.yaml)が発行する短命・opaqueなFUMINIWA access tokenだけである。Apple authorization code、identity／access／refresh token、subject、email、氏名、relay addressをSync APIへ渡さない。authenticated capabilitiesはopaque AccountID、AccountAuthEpochと、それらをserver instance／protocol epochへbindしたAccountFenceを返す。通常token rotationと同一Apple identityへの再認証ではfenceを変えず、security-scope epoch変更時は旧cursor／presence／Intent／Attemptをquarantineしてfull bootstrapする。

## 正の所在

- [`openapi.yaml`](openapi.yaml): HTTP path、request／response、typed error、limit、receipt／retry契約
- [`snapshot.schema.json`](snapshot.schema.json): Snapshot manifest wire shape
- [`publish-command.schema.json`](publish-command.schema.json): 通常head publish command wire shape
- [`entity-schemas/`](entity-schemas/): structured entity payloadのclosed schema
- [`fixtures/`](fixtures/): canonical bytes／hash、state machine、migration、retention、backup、portable境界のcross-language acceptance
- [`errors.md`](errors.md): OpenAPIのtyped errorをclient recoveryへ写像する規則
- [`../../auth/v1/`](../../auth/v1/): Sign in with Apple native、FUMINIWA session、token rotation、AccountAuthEpochのversioned wire／fixture
- [`../../SNAPSHOT_SYNC.md`](../../SNAPSHOT_SYNC.md): 製品不変条件、local SQLite／CAS、同期・競合・履歴・移行の全体設計
- [`../../SNAPSHOT_SYNC_HANDOFF.md`](../../SNAPSHOT_SYNC_HANDOFF.md): Lunaへ渡す実装順と禁止事項

`SnapshotManifest`と`PublishHeadCommand`は外部JSON Schemaが正で、OpenAPI内の自己完結copyは構造等価でなければならない。比較は両schemaの`$ref`を完全inlineし、inline後に参照不能となったroot `$defs`を除去し、annotationと`x-fuminiwa-*`だけを除いたnormalized JSONを再帰比較する。この順序を変えたり、他のvalidation keywordを落とした差があればR0失敗とする。R0 conformance runnerはnormalizerのexpected normalized JSON fixtureも固定する。semantic whole-work invariant、calendar-valid timestamp、portable projection limitはJSON Schemaだけで完了せず、OpenAPI、設計本文、fixtureを合わせて実装する。

## R0実装conformance条件

1. D-078の`serverReadableV1`／E2EEなし、Sign in with Apple native、FUMINIWA opaque session、同一identity再認証をsync＋auth OpenAPI／fixtureで相互検証する。
2. Swift／Rust／C#が全valid fixtureで同じJCS bytes、ObjectID、SnapshotID、command digestを返し、全invalid fixtureを同じ分類で拒否する。
3. OpenAPI parse、全local `$ref`、operationId一意性、外部schema構造等価、JSON Schema meta-validationを機械検査する。
4. save／Intent、lost ACK、upload expiry、cursor、account fence、safe materialization、3択、retention、backup、migrationのscenario fixtureを3実装で共有する。
5. conformance実装中に生成client／server codeを正にせず、契約変更時はschema、OpenAPI、fixture、Decisionを同じcommitで更新して再監査する。

最低限の静的検査例:

```sh
find docs/sync/v1 -name '*.json' -print0 | xargs -0 -n1 jq -e .
ruby -e 'require "yaml"; YAML.safe_load(File.read("docs/sync/v1/openapi.yaml"), aliases: true); puts "openapi yaml ok"'
git diff --check
```

これだけではJCS hash、external schema equivalence、semantic fixtureの合格を意味しない。R0では専用のcross-language conformance runnerを先に実装し、そのrunnerをSwift／Rust／C#の各CI入口から同じfixtureへ向ける。
