# 現行v2の更新・取り込み境界

通常アプリは既存のSQLite v2を開き、作品転送は検証済み`.novelpkg`の明示Import / Exportを使う。実装は`NovelSyncV2PortableBridge`、`NovelSyncV2Store`、各Appのportable adapter。読込失敗を空作品に置換しない。

旧v1 DB／archive専用のstandalone移行ツールは現行build graphに存在しないmoduleへ依存していたため削除した。現在の移行手順として実行しない。原稿・DB・手動退避はこの整理の対象外で、過去のツールsourceはGit履歴で参照できる。

## 保つ永続契約

- 稼働DBのschema更新には、チェックイン済みの順序付きSQL migrationを使う。既存migrationの削除・編集・番号詰めはしない。serverとclientそれぞれの検証・scopeを維持する。
- migration ledger／staging tableは既存schemaの一部として保持する。backupの作成、staging、検証、adoptionは別の状態であり、backupができただけでlive作品へ取り込まない。
- 外部データの取り込みは新しい作品として検証し、現行作品を上書き・resetしない。本文・object・manifest・account scopeの検証を迂回しない。
- server更新は固定role・server instanceを照合し、backupと隔離復元を先に確認する。手順は[deployment](deployment.md)、復旧は[運用](../../ACCOUNT_RETENTION_OPERATIONS.md)。

## D-108: 内容同値表の修復

`-- Receipt equivalence repair (D-108).`を既存SQLの末尾へ追加し、旧checksumから同じtransactionで進める。`snapshot_remote_equivalents`の異なるremote idを、検証済みcompleted `publish`／`resolveDevice`／`restore`のcanonical responseでheadとintent snapshotが一致する受領世代へ戻す。その証拠がなく祖先noChangesだけがある誤対応は削除する。temporary evidence tableはmigration内で破棄し、変更後のchecksumをattestする。再起動で修復を再実行せず、本文・添付・current・acknowledged head・command／receipt履歴は書き換えない。
