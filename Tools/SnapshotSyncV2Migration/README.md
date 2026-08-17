# Snapshot Sync v2 legacy export

これはv2切替前の旧v1 SQLiteを`.novelpkg` backupへ変換する、live appから分離された
macOS専用の移行ツールです。入力SQLiteはread-onlyで開き、出力はstage rootだけへ
書き込みます。stageにはadoption markerを作らないため、途中終了しても通常の作品棚へ
取り込まれません。

```sh
swift run --package-path Tools/SnapshotSyncV2Migration snapshot-sync-v2-export \
  --source-is-verified-archive \
  --expected-work-count 62 \
  /path/to/legacy-v1.sqlite \
  /path/to/classification.csv \
  /path/to/new-stage-root \
  /path/to/legacy-archive-root \
  /path/to/legacy-archive-root/sha256-manifest.txt
```

classification CSVは8列（`workID,classification,currentSnapshotID,currentSnapshotCreatedAt,currentSnapshotLocalGeneration,acknowledgedHeadSnapshotID,acknowledgedHeadGeneration,evidence`）です。分類はタイトルから推測せず、
ledgerの証拠を使います。受理する分類は`verified`、`verified_candidate`、`quarantine`、
`legacy_quarantine_test_batch`、`needs-review`、`needs_review`、
`legacy_quarantine_ambiguous_user_touched`です。
各出力は`verified/`、`quarantine/`、`needs-review/`へWorkID名で保存されます。`--expected-work-count`は必須で、今回の監査済みarchiveでは`62`を指定します。

v2へcommitするmigration CLIは、stage内のreportだけを信頼しません。stage外の監査済みauthorityを指定し、authorityのcanonical JSON SHA-256とoperator identityを別経路で渡す必要があります。

```text
--trusted-authority-root <authority-root>
--trusted-authority <authority-root/provenance.json>
--expected-authority-digest <sha256>
--expected-authority-id <authority-id>
```

authorityはsource SQLite、archive manifest、classification ledgerのdigestとWorkID別inventory evidenceを記録します。`verified_candidate`は採用候補に過ぎず、authority側のdispositionが文字通り`verified`でなければcommitされません。authority pathのstage内配置、同一ファイル指定、symlink、path swap、canonical bytes変更は拒否されます。

各作品について次を検証します。

- canonical `WorkSnapshot`のdecode/materialize
- manifest bytesのSHA-256とsnapshot IDの一致
- legacy v1 document content type（`application/json`または`application/vnd.fuminiwa.entity+json;version=1`）の一致
- document IDとworks行の一致
- `NovelpkgRepository`での書き出しとlogical read-back
- v1 object全行のbyte count／SHA-256（問題はledgerへ記録）

添付やopaque resourceはv1 SQLiteに含まれないため自動補完しません。raw archiveを別途
read-only保全し、生成ledgerにその事実を記録します。packageは開ける作品内容のportable
projectionであり、旧DBの履歴・添付・opaque resourceの完全な代替ではありません。

入力archive root、SQLite、SHA-256 manifestはregular file／非symlink／非書込であること、
SQLiteのdigestがmanifestに記録されていること、stage rootがarchive root外であることを
要求します。開始時と終了時にSQLite digestを再確認します。stageには`migration-run.json`、
Workごとの`.state/` sidecar、最後に全件成功したときだけ`COMMITTED` markerを書きます。
markerがないstageは採用対象ではありません。既存stage packageはsource digest、snapshot
ID、projection digestのsidecarが一致する場合だけread-backして再利用します。
