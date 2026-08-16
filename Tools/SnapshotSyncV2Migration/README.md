# Snapshot Sync v2 legacy export

これはv2切替前の旧v1 SQLiteを`.novelpkg` backupへ変換する、live appから分離された
macOS専用の移行ツールです。入力SQLiteはread-onlyで開き、出力はstage rootだけへ
書き込みます。stageにはadoption markerを作らないため、途中終了しても通常の作品棚へ
取り込まれません。

```sh
swift run --package-path Tools/SnapshotSyncV2Migration snapshot-sync-v2-export \
  /path/to/legacy-v1.sqlite \
  /path/to/classification.csv \
  /path/to/new-stage-root
```

classification CSVの最初の2列は`workID,classification`です。分類はタイトルから推測せず、
ledgerの証拠を使います。受理する分類は`verified`、`verified_candidate`、`quarantine`、
`legacy_quarantine_test_batch`、`needs-review`、`needs_review`、
`legacy_quarantine_ambiguous_user_touched`です。旧inventoryでverifiedをWorkID自身で表す
形式も受理します。各出力は`verified/`、`quarantine/`、`needs-review/`へWorkID名で保存されます。

各作品について次を検証します。

- canonical `WorkSnapshot`のdecode/materialize
- manifest bytesのSHA-256とsnapshot IDの一致
- document IDとworks行の一致
- `NovelpkgRepository`での書き出しとlogical read-back
- v1 object全行のbyte count／SHA-256（問題はledgerへ記録）

添付やopaque resourceはv1 SQLiteに含まれないため自動補完しません。raw archiveを別途
read-only保全し、生成ledgerにその事実を記録します。既存stage packageが同じ論理作品なら
read-backして再利用するため、同じ入力で再実行できます。
