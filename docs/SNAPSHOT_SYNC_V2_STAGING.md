# Snapshot Sync v2 — LAN stagingのTLS確認

LAN入口のTLS検証を扱う。Composeの既定値は以下。現在の公開Tunnelも同じLAN入口へ接続するため、LANという理由だけで隔離試験環境と扱わない。DBを使う試験は別の使い捨て環境で行う。

```text
URL:     https://192.168.11.5:8443
project: fuminiwa-sync-v2-role-split
edge:    fuminiwa-sync-v2-role-split-edge
```

目的は、試験端末が正しいstaging CAを信頼し、その通信経路でAuth／Sync v2へ到達できると確認すること。Caddyのinternal CAは本番trust anchorではない。公開root証明書だけを扱い、private keyのコピー、`-k`、アプリの証明書検証無効化は行わない。

## 現行export scriptの制約

[Scripts/export-sync-v2-staging-ca.sh](../Scripts/export-sync-v2-staging-ca.sh)は公開rootの取得、SAN確認、`curl --cacert`によるAuth capabilities確認を行う。ただし現在はedge名が`fuminiwa-sync-v2-edge`に固定され、role-split Composeと一致しない。container名を指定する引数もない。**role-split環境でそのまま使える手順ではない。** 修正は[CODE_HEALTH](CODE_HEALTH.md)の残件。

scriptを更新する場合は、確認したexact v2 edgeだけを対象にし、従来の非破壊・公開証明書のみという境界を保つ。更新までは運用者からそのedgeの公開CAファイルとfingerprintを受け取る。旧containerが残っていても、別edgeのrootを対象証明書として採用しない。

修正後に使うexportの入口は次のとおり。

```sh
Scripts/export-sync-v2-staging-ca.sh \
  --output "$HOME/Downloads/fuminiwa-sync-v2-root.crt"
```

scriptはSSH／sudoの対話入力が必要になる場合があるがpasswordを読み取って保存しない。remoteの一時領域には公開CAだけを置く。成功メッセージは現状以下だが、namespace文字列のみを検査しており、**`syncProtocolEpoch=2`を証明していない**。

```text
leaf SAN: IP Address:192.168.11.5
HTTPS auth capabilities: HTTP 200 (v2 namespaces verified)
```

## Trustの設定

取得したrootのSHA-256 fingerprintを別の信頼できる経路と照合する。過去のfingerprintや表示名だけで現在の正しいCAと判断しない。

macOSでは確認済み公開CAだけをlogin keychainへ追加する。

```sh
security add-trusted-cert \
  -d -r trustRoot \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  "$HOME/Downloads/fuminiwa-sync-v2-root.crt"
```

iPhone／iPadでは確認済み`.crt`を端末へ渡してprofileをインストールし、設定の **一般 → 情報 → 証明書信頼設定** で対象rootのtrustを有効にする。表示名だけに頼らずfingerprintを照合する。これは端末全体のstaging trustなので、検証後は対象を確認してKeychain Accessまたは端末設定から解除・削除する。

## 成功条件

検証時の日時、exact project／edge、image、root fingerprintと以下の結果を記録する。tokenやprivate keyは記録しない。

- 端末と同じ通信経路でSANとTLS chainが一致する。
- public `/v1/auth/capabilities`がHTTP 200を返し、Auth epoch 1とSync epoch 2を確認できる。
- signed-in appでauthenticated `/v2/capabilities`のAccountID／server instance／Fenceがsession bindingと一致する。
- 対象試験Workのremote headをread-backできる。

container healthとpublic Auth capabilitiesは接続の一部だけを確認する。authenticated scopeや作品同期の代わりにはならない。Axumの8092番portはCompose内部に留める。新規構築・再起動・権限分離の手順は[server README](../SyncServerV2/README.md)と[deployment契約](sync/v2/deployment.md)を参照する。
