# Snapshot Sync v2 の公開入口

構成上の公開URLは`https://sync.serika.work`。既存の`home-server` Cloudflare Tunnelから自宅サーバーへ接続する。アプリ共通defaultは`NovelKit/Sources/NovelAuth/FuminiwaRuntimeEnvironment.swift`、有効なHTTPSの`fuminiwa.syncServerURL`個別設定を優先する。

```text
macOS / iOS → https://sync.serika.work
  → 既存cloudflared → https://192.168.11.5:8443
  → Caddy → Snapshot Sync v2 server:8092 → PostgreSQL
```

公開URLとLAN入口は同じデータ・server instanceを使う。通常保存は端末SQLiteで完結し、圏外やサーバー停止中も編集を続ける。接続復帰後にremote workerを再開する。Tunnelの追加は一般公開・全実機受入の完了を意味しない。

## 既存ルートの設定

| 項目 | 設定 |
| --- | --- |
| ホスト名 | `sync.serika.work`（パス指定なし） |
| サービスURL | `https://192.168.11.5:8443` |
| HTTP Host・配信元サーバー名 | `192.168.11.5` |
| CAプール | `/config/fuminiwa-sync-v2-root.crt` |
| 配信元のTLS検証 | 有効 |

cloudflaredの`/config`はホストの`/DATA/AppData/casaos-cloudflared/config`。公開CAは`fuminiwa-sync-v2-role-split-edge`の`/data/caddy/pki/authorities/local/root.crt`に由来する。CA更新時は配置先とfingerprintを照合し、接続を再確認する。private key・Tunnel tokenはGitやログへ置かない。

アプリ→Cloudflareとcloudflared→Caddyの両方でTLS検証する。公開URL利用時は端末への内部CA追加が不要。認証はAuth v1のApple nativeログインとFUMINIWA bearerで行い、ブラウザ用Accessログインは挟まない。別サービスのルートを変更しない。

## 変更時に確認すること

設定変更前に対象ルートとDB・構成のbackupを確認する。変更後はTLS検証を有効にしてAuth capabilitiesの200、Auth epoch 1／Sync epoch 2、server instance、認証なしのSync capabilitiesの401を確認する。同期の変更を伴う場合は、認証済みscopeと対象試験作品のheadもread-backする。

過去の接続・実機結果はGit履歴へ集約する。本文書は現在の疎通・同期完了の証拠ではない。実装残件は[CODE_HEALTH](CODE_HEALTH.md)、serverの復旧は[自動運用](ACCOUNT_RETENTION_OPERATIONS.md)。

## 切り戻し

公開入口を止めるときは`sync.serika.work`のルートと対応DNSだけを対象にする。LANへ戻す場合は同じserverのHTTPS originを指定し、[LAN CAのtrust](SNAPSHOT_SYNC_V2_STAGING.md)を設定する。ネットワーク変更のためにDB、Keychain、AccountFenceをresetしたり古いDBへrestoreしたりしない。

Cloudflare側の設定を変更する際は[公開アプリケーション](https://developers.cloudflare.com/tunnel/get-started/)と[配信元TLS設定](https://developers.cloudflare.com/tunnel/advanced/origin-parameters/)を参照する。
