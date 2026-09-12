# Snapshot Sync v2 — 独立した旧データ移行ツール

これは旧v1 SQLiteのexport、独立したprovenance authority生成、v2 client SQLiteへのadoptionを扱う、live appから分離されたmacOS専用packageです。2026-09-12に`Package.swift`とCLI sourceを照合しました。現在の製品開発で毎回使うツールではなく、明示された移行作業だけを対象にします。

| executable | 成果物 | 成功の境界 |
| --- | --- | --- |
| `snapshot-sync-v2-export` | read-only package stageと証拠 | portable backupの生成。v2採用ではない |
| `snapshot-sync-v2-authority-builder` | stage外のprovenance authority | 独立入力との照合。v2採用ではない |
| `snapshot-sync-v2-migration` | verifiedなclient SQLite adoption | 明示commit・read-back。remote publishではない |

規範とquarantine条件は[migration.md](../../docs/sync/v2/migration.md)、今の優先順位は[現行ハンドオフ](../../docs/SNAPSHOT_SYNC_V2_HANDOFF.md)を参照してください。以下はexport／authority生成の参照手順です。実行前に対象archive・期待件数・digestを今回の証拠へ置き換えます。入力SQLiteはread-onlyで開き、出力はstage rootだけへ
書き込みます。stageにはadoption markerを作らないため、途中終了しても通常の作品棚へ
取り込まれません。

```sh
swift run --package-path Tools/SnapshotSyncV2Migration snapshot-sync-v2-export \
  --source-is-verified-archive \
  --expected-work-count <verified-work-count> \
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
各出力は`verified/`、`quarantine/`、`needs-review/`へWorkID名で保存されます。`--expected-work-count`は必須です。以前の監査例は62件でしたが、固定値として再利用せず今回のarchive inventoryから指定します。

stageのprovenance format v2では、旧SQLiteのwire証拠とpackage read-back後の採用証拠を別の値として記録します。`sourceWireSnapshotID`／`sourceWireSnapshotDigest`／`sourceProjectionDigest`／`sourceObjectClosureSHA256`はread-only SQLiteの独立解析から、`adoptionSnapshotID`／`adoptionProjectionDigest`／`inventoryEvidenceSHA256`は`.novelpkg`のread-backから再計算します。`sourceProjectionVersion`と`adoptionProjectionVersion`も別々に必須です。`snapshotID`と`projectionDigest`は互換aliasに過ぎず、sourceとadoptionを代用できません。`inventoryEvidenceSHA256`は絶対pathを除いたcanonical JSONで、空ディレクトリを含むpackage treeの全entryを対象にします。source projectionとadoption projectionは異なる正当なdigestであり、builderは両者を比較しません。

v2へcommitするmigration CLIは、stage内のreportだけを信頼しません。stage外の監査済みauthorityを指定し、authorityのcanonical JSON SHA-256とoperator identityを別経路で渡す必要があります。

```text
--trusted-authority-root <authority-root>
--trusted-authority <authority-root/provenance.json>
--expected-authority-digest <sha256>
--expected-authority-id <authority-id>
```

authorityはsource SQLite、archive manifest、classification ledgerのdigestとWorkID別inventory evidenceを記録します。`verified_candidate`は採用候補に過ぎず、authority側のdispositionが文字通り`verified`でなければcommitされません。authority pathのstage内配置、同一ファイル指定、symlink、path swap、canonical bytes変更は拒否されます。

authorityは既存stageから専用builderで生成します。builderはstageを変更せず、stage外のread-only classification/archive/SQLiteとoperator指定の期待digestを突き合わせ、別の新規rootへ`provenance.json`をatomic作成します。

```sh
swift run --package-path Tools/SnapshotSyncV2Migration snapshot-sync-v2-authority-builder \
  --stage-root /path/to/stage \
  --classification /path/to/classification.csv \
  --archive-root /path/to/legacy-archive-root \
  --archive-manifest /path/to/legacy-archive-root/sha256-manifest.txt \
  --source-sqlite /path/to/legacy-archive-root/library.sqlite \
  --expected-classification-digest <sha256> \
  --expected-source-sqlite-digest <sha256> \
  --expected-archive-manifest-digest <sha256> \
  --expected-work-count <verified-work-count> \
  --authority-id <operator-identity> \
  --authority-root /path/to/new-authority-root
```

builderの出力JSONに含まれる`authorityDigest`と`authorityID`を、adopterのcommit引数へ別経路で渡します。既存のauthority rootや入力と重なる出力root、symlink、書込み可能な入力、直前のdigest変更は拒否されます。

builderはstage report／run／`COMMITTED`／`.state` sidecar／package treeをauthorityの根拠として信頼せず、source SQLiteをimmutable read-onlyで再解析し、WorkID・document ID・source object closure・classification 8列（createdAt/local generation/ack head ID+generation/evidence）・package adoption snapshot／projection・path-independent inventoryをexact照合します。object/source row issueが1件でもあれば拒否します。manifest各entryはrealpath、portable Unicode/casefold path key、filesystem identity（device/inode）を検証し、symlink・hardlink alias・collision・SQLite entry重複を拒否します。出力直前にはclassification、source SQLite、archive manifest、sealed stage treeを再hashします。exporterの最終化は全entryを非書込み（file `0444`／directory `0555`）へsealし、既存COMMITTED stageは内容一致を確認してから明示的に再sealできます。authorityはsibling temporary rootを完全に再hash・sealしてからfinal rootへatomic renameするため、失敗時にpartial finalを残しません。

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
