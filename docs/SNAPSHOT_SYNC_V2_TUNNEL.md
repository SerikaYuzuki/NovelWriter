# Snapshot Sync v2 の Cloudflare Tunnel

2026-09-13、既存の `home-server` Tunnel に `sync.serika.work` を追加した。
公開入口の追加であり、一般配布・Production受入の完了を示すものではない。

## 接続構成

```text
macOS / iOS
  → https://sync.serika.work
  → Cloudflare Tunnel (既存 cloudflared)
  → https://192.168.11.5:8443 (既存 Caddy)
  → Snapshot Sync v2 server:8092
```

両Appは `NovelAuth/FuminiwaRuntimeEnvironment.swift` の共通defaultを使う。
有効なHTTPSの `fuminiwa.syncServerURL` 個別設定は引き続き優先する。
今回確認したMac・iPhoneには個別設定がなかったため、データmigrationや設定の強制上書きは不要だった。
HTTPの旧v1設定は採用しない。テストのnetwork-disabled境界も維持する。

TunnelとLAN入口は同じCaddy・server・PostgreSQLへ接続する。
server instance、Sync epoch 2、AccountFence、作品ID、SQLiteを変更せず、
認証済みsessionは既存Keychainから引き継ぐ。通常保存は従来どおりローカルで完結する。

## Dashboardの設定

既存Tunnelの「ルート」から公開アプリケーションを追加する。
既存の他サービスのルート・順序は保持する。

| 項目 | 値 |
| --- | --- |
| ホスト名 | `sync.serika.work` |
| パス | 指定なし |
| サービス URL | `https://192.168.11.5:8443` |
| HTTP Host ヘッダー | `192.168.11.5` |
| 配信元サーバー名 | `192.168.11.5` |
| CA プール | `/config/fuminiwa-sync-v2-root.crt` |
| TLS 証明書検証を無効化 | オフ |

Caddyの公開CA証明書 `root.crt` だけをcloudflaredの永続mountへ配置する。
このホストでは `/DATA/AppData/casaos-cloudflared/config` が `/config` へmountされている。
CAは既存 `fuminiwa-sync-v2-role-split-edge` 内の
`/data/caddy/pki/authorities/local/root.crt` から取得した。
秘密鍵やTunnel tokenをリポジトリ・ログへ保存しない。
Caddy CAを再生成する場合は、このCAプールも更新して接続を再検証する。

Cloudflare側と配信元側の両方でTLSを使い、配信元証明書の検証を有効にする。
アプリ側に内部CAを追加する必要はない。ブラウザ用Accessログインを挟まず、
既存のAuth v1・Apple nativeログインとSync v2 bearer認証を使う。
公開URLを知るだけでは作品にアクセスできない。

参照: [公開アプリケーション](https://developers.cloudflare.com/tunnel/get-started/)、
[配信元のTLS設定](https://developers.cloudflare.com/tunnel/advanced/origin-parameters/)。

## 反映と確認記録

- 公開前に対象PostgreSQLのcustom-format dumpとcloudflared設定を非公開の運用backupへ保存。
  `pg_restore --list`でarchiveを読めた。今回、実restoreは行っていない。
- Mac・iPhoneのv2 SQLiteも更新前にbackupし、両方の`integrity_check`が`ok`。
- 公開URLの `/v1/auth/capabilities` はHTTPS検証を有効にして200。
  LANと同じserver instance、Sync namespace、epoch 2を確認。
- 認証なしの `/v2/capabilities` は401。両応答の`Cache-Control: no-store`を確認。
- Dashboardでルート追加とDNS作成を確認。既存3ルートも保持された。
- 共通endpoint・Auth HTTP transportの24テストが成功。macOS／iOSの署名済みRelease buildが成功。
- `Scripts/check.sh`はconformance・構造確認を通過した後、今回未変更の
  `EpisodeRenamePresentation.swift`、`EpisodeRenameTests.swift`、
  `ProductionUnboundAttachmentTests.swift`の既存SwiftFormat違反で停止。
  全体チェック成功とは扱わない。
- Mac更新版の起動、既存サインイン、Cloudflare宛443接続を確認。
  既存の同期テスト作品で明示同期が「同期中」から「同期済み」になった。
- iPhoneへの更新インストールが成功。ロック解除後の起動も成功。
  起動後に取得したSQLiteの`integrity_check`も`ok`。

今回のHTTP確認と変更なし同期は、両端末の新規編集の往復・競合・障害復旧をすべて受入済みとする証拠ではない。
公開後のモバイル通信・offline編集テストで判明した停止原因と修正は下記。

## offline編集テストで判明した停止原因

1. `publish`の`noChanges`／競合受領後、端末内にある履歴も毎回HTTPで取り直していた。
   問題のreceiptが指す履歴は203件・242件で、取得処理の128件上限を超えていた。
   exact scopeのSQLite保存済みSnapshotを親履歴の検証済み起点として再利用する。
   受信後、local編集のため未採用となったverified Inboxもbytesを再検証して再利用し、
   その親は引き続き辿る。未検証Inboxや別work／account／fenceは再利用しない。
   同じHTTP取得内で重複するObjectIDも一度だけ取得する。
2. remote descendantの受領と、その採用前のlocal編集が重なると、最新のacknowledged headを
   local candidateの比較元として送っていた。そのheadがcandidateの祖先でない場合、
   serverは`422 lineageViolation`でcommit前に拒否する。
   publish用の比較元はcandidateの実際の祖先にある検証済みheadから選ぶ。
   acknowledged headの単調増加、local本文、sealed bytesは変更しない。
3. 旧版が既に封印した不正な比較元のpublishは、まず同じID・bytesで再送する。
   正確なpre-commit `422 lineageViolation`応答を受け、かつ修正後の比較元が異なる場合だけ、
   旧commandとintentをquarantineして証拠を保持し、現在のlocal checkpointから新intentを計画する。
   応答消失・認証失敗・不明な422・receipt不一致を新commandへ置き換えない。
4. Releaseでも失敗stageと型・enum名だけを診断ログへ記録する。
   原稿、path、token、HTTP本文、errorのassociated valueは記録しない。

追加回帰検証では、130件の保存済み履歴、130件の未採用verified Inbox、
no-change／remote descendant、scope不一致、重複object取得、offline編集中の遅延receipt、
旧publishの保持と再計画を確認した。関連8テストは成功。
追加の競合受信修正後、最終SwiftPM全体は499件すべて成功した。
途中の実行では既知の`ProductionInboxIsolationTests`のwrong-work待機テストが失敗しており、
不安定性は残る。`check.sh`は既存3ファイルの整形エラーで停止する。

この時点では未知の履歴に128件上限が残っていた。後続の
[長い履歴の取り込み改善](SNAPSHOT_SYNC_V2.md)で、非再帰の順次取得へ変更し、
128件の打ち切りを除去した。

## iOSの履歴表示

作品ホームには「履歴を見る」の入口だけを置き、履歴は専用sheetの`List`内でスクロールする。
件数が増えても作品ホームの設定・書き出し操作が下へ押し出されない。
履歴の取得はsheetを開いたときに行い、追加読み込みと復元前の確認、
document session／account scopeの検査を維持する。

## 競合受信と実機確認の追記

verified Inboxの競合受信が単一snapshotとして再stageされ、比較元をnilに落とし、
serverのconflict ID／revisionを引き継がずlocal生成していた。
既に検証したgraphをそのまま使用し、応答で確認済みのbase／ID／revisionを
transaction内で記録するよう修正した。別scope、未検証Inbox、古い世代、
別の競合番号の再配信は拒否する。2段のremote履歴、共通祖先、再配信とID不一致の回帰検証は成功。

最終macOS／iOS Release build、iPhoneへの更新・起動は成功。
iOSの履歴専用画面は利用者が実機で確認した。
Macの停止中publishはconflictPending receiptの受領と選択画面まで復旧し、
利用者が「サーバーの版を採用」を選択後、Macの「同期済み」を確認した。
iPhoneのモバイル通信は端末設定でオフだったため、利用者がオンへ変更した。
競合解決後、利用者がWi-Fiを切ったiPhoneで再試行し、「同期済み」を確認した。

## 運用・切り戻し

同期にはサーバーPCと既存cloudflaredの稼働が必要。
停止・圏外でも端末内の編集と保存は続けられ、通信復帰後に従来のworkerが再開する。
両端末のoffline編集が分岐した場合の既存の競合処理は変更していない。

公開入口を止める場合は、追加した `sync.serika.work` のルートと対応DNSだけを対象にする。
LAN接続へ戻す際は、同じv2サーバーのHTTPS URLを個別設定または共通defaultに指定する。
LANではCaddy CAの端末側trustが必要。DB・Keychain・AccountFenceをresetしない。
このネットワーク変更の切り戻しのために古いDB backupをrestoreしない。
