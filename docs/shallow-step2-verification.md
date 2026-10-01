# D-106 Step 2 実装・検証記録

2026-10-02。対象は `codex/sync-v2-review-fixes` の未コミット差分。実データ・実アカウント・実サーバーを使用せず、デプロイもしていない。Step 3 と実機受入は対象外。

## 実装範囲

- **Store / migration**: `shallow_boundaries`・`history_backfills` を末尾追加。既知の末尾マーカーを順に検証・適用し、既存 schema の厳密な checksum / DDL attestation を維持。boundary の UPDATE 禁止・実 parent edge のない DELETE 禁止、B0–B2、削除順序、登録祖先 cache の失効を実装。
- **Install / backfill**: D-102 の単一 transaction で H と journal を設置。ページの entity 検証は actor 外で行い、接続証明・anchor・binding・CAS・削除・既存 bytes・unique object budget の確認と cursor 保存を一括 commit。本文 current・generation・未送信 intent は変更しない。
- **Lineage**: 未取得祖先を既知の非祖先や disjoint と扱わず `historyIncomplete` にする。取得済みの明示された共通 base では探索を止め、新しい通常競合を扱える。Runtime の取得も boundary で停止する。
- **Runtime / Application**: head mode と初回 mode 拒否時の full import fallback、closed group 単位の再開、fence 変更時の cursor reset、別 account の park、401 / 404 の suspend。全体で一本の coordinator を install 後・起動時に再開し、account transition・constrained network でキャンセルする。取得対象は端末に取り込まれた作品のみ。
- **UI**: 棚の同期状態とは独立した進捗 note、履歴 item ごとの availability と未取得表示。優先取得・未取得版の復元・競合待機文言は Step 3 の TODO に留めた。
- **契約・fixture**: D-106、同期概要、state-machine、ui-state、CODE_HEALTH を更新。`shallow-install-backfill.json` と canonical head / backfill payload を Swift・Rust・Python で共有。

## 設計の具体化・未達事項

1. **既存 checksum 一件は未解決**: 既存コードの retired-restore 候補 `6b089b87ef6118cbf04e89b3e46295b8b1297463e68cde8e785d44149c76c467` は、既存 DDL builder から再現できない（生成値は `481c7eb6…`）。正確な旧 schema の根拠なしに受入条件を広げず、既存の fail-closed を維持した。従って「全旧 checksum の移行成功」は未達。成功を確認したのは `745d947…`・`e38615c…`・`9af3fd4…`、末尾追加前の `3e4e6e4…` と `4154c66…`、fresh schema。`9af3fd4…` の既存 builder にあった改行欠落と transfer DDL の空白差は修正した。
2. **進捗表示は MB**: server の `totals.items` は manifest と object の合計で snapshot 数ではない。誤った snapshot 総数を表示せず、設計で許される MB 表示を使用する。値は commit 済み祖先の manifest と H で共有されていない object の dedupe 後の byte 数。
3. **成功 fixture を追加**: Step 1 の transport fixture は `work/document` がなく、完全な小説 entity として install できない。元 fixture の strict rejection も確認し、同じ Rust planner が出力する有効な entity graph を新 scenario として追加した。検証を緩めて既存 fixture を通してはいない。
4. **共通 base の探索打切り**: 明示された materialized base に到達した branch はそこで打ち切る。それ以外の branch に boundary が残る場合は incomplete のまま。これにより H より新しい通常競合を阻止しない。nil base・古い未取得 base の判定は引き続き retryable。

## 実行結果

標準の `cd NovelKit && swift test` と `./Scripts/check.sh` は sandbox 内の cache / Xcode-build-system / macro plugin 制約で完走できなかった。代替実行には以下を使用した。

```sh
cd NovelKit
env CLANG_MODULE_CACHE_PATH=/tmp/d106-clang-cache \
    SWIFTPM_MODULECACHE_OVERRIDE=/tmp/d106-swift-cache \
    swift test --disable-sandbox --scratch-path /tmp/d106-final \
    --build-system native --no-parallel
```

- D-106 対象 + opt-in benchmark: 27 tests 成功（parameterized cases を含む）。CAS / binding / cancellation rollback、通常作品の親検証、incomplete lineage、再開・fence reset・park、401 / 404 suspend、H1 Inbox、malformed page、full import 同値、削除、cache、coordinator、old-server fallback、Rust 共有 fixture を含む。
- 追加の `editPromoteAndPublishUsePinnedHeadDuringBackfill`: **成功**。shallow install → edit → promote → H を expected head とする publish seal / ACK → backfill の完了までを確認。
- native 全体の初回 serial 実行: Keychain 関連の二 suite を除き 643 tests、5 issues。4 issues は一つの pasteboard test、残り一件は既存 keep-both test。keep-both は変更前 HEAD を `/tmp` に展開して同じ native 条件で単独実行しても同じ行で失敗した。
- 最終 native 全体実行: 上記の Keychain 二 suite と `localFirstEditabilityKeepsAllMutationPathsAvailable`・`productionKeepBothOpensCloneBeforeTransport` を明示除外し、**641 tests / 54 suites 成功**（86.206 s）。除外は全 suite の成功を意味しない。
- Keychain は sandbox で status `-50`、pasteboard は `readSelection` が false。これらの実 OS service 成功は確認できていない。
- Python independent conformance: **75 vectors 成功**。
- Rust offline tests: **104 passed / 1 ignored**。DB を使う opt-in Gate は未実施。共有 fixture を server planner が同じ payload / cursor / totals に生成する検査を含む。
- macOS / iOS app `Debug-Test`: **試行したが失敗**。Package cache 書込みが sandbox で拒否され、iOS は CoreSimulatorService も利用できず、app test の実行まで到達していない。project 生成は成功。
- structure、依存境界、test-network 境界、AI 分離、sync-v2 境界: **成功**。
- SwiftFormat lint: **成功**。SwiftLint: **error なし**（既存・追加ファイルの warning あり）。source ≤800行、function body ≤100行、tuple ≤2 の error gate を通過。
- 実機画面・Low Data Mode 実機・配布受入: **未実施**。

## 合成ベンチマーク

`FUMINIWA_IMPORT_BENCHMARK=1`、native / serial、一時 SQLite、1,500 snapshots、H は 29 entries。時間は install 開始から `open` が返るまでで、ネットワークと画面描画を含まない。一回の計測値であり実機 SLA ではない。

| 項目 | 実測 |
| --- | ---: |
| full import → open | 3.447769 s |
| head-first → open | 0.02691825 s |
| backfill 256 wire items（128祖先、各 title object + manifest） | 37.585917 ms |

write lock は `BEGIN IMMEDIATE` 直前から `COMMIT` 完了まで。256-item fixture の <100 ms assertion は成功。別作品 checkpoint と full install の競合測定では checkpoint 最大 0.751 s だった。この値は full install の既存処理であり、backfill page の lock 時間とは別である。

## Reviewer に見てほしい箇所

1. `Schema.open` の checksum chain、旧 candidate の厳密な attestation、移行途中の rollback / 同時 opener、未解決 `6b089b87…` の扱い。
2. `attestEncodedRows` の parent / boundary UNION ALL、同じ child の boundary だけを認める `validateParents`、通常作品の full attestation、すべての snapshot 挿入経路での B2。
3. ConflictLineage の incomplete 判定と materialized common-base cut。未取得祖先を非祖先・disjoint・nil base に変換していないこと。
4. merge の child-before-parent 順序、既存 boundary または証明済み root 祖先だけを受け入れる page transaction、anchor / bytes / unique-object budget。
5. head / backfill cursor の種類・scope 検証、未完 group の replay、closed group cursor の同時保存、初回拒否だけの fallback。
6. backfill actor 外検証と transaction 内の再検査、autosave への lock 負荷、各 commit の registeredAncestorCache 失効。
7. account suspension / constrained network の cancel と再開競合、古い progress callback の generation gate、棚の本文保存状態と履歴取得 note の分離。
