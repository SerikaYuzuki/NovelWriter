# コードの現状と検証

2026-09-12、文書改訂前の`32e60bdf6`をローカルで確認した。実装の構成と未完了事項を記録する。過去の説明は[2026-08版](archive/2026-09-12-CODE_HEALTH.md)に保存した。

## 今回の実装更新

2026-09-12、専用作品一覧・ログイン導線、伏線下段、AI支援、iOS導線、保存中のrevision競合・autosave自己取消・接続復帰wakeを修正した。[作業記録](WORKBENCH_IMPLEMENTATION_20260912.md)を今回の結果の正とする。以下の元の調査表は文書改訂時点の記録であり、更新前の未接続項目を現在の状態と混同しない。

## 1. 現行の入口

| 対象 | 確認する場所 |
| --- | --- |
| 通常target / 除外source | [project.yml](../project.yml) |
| 共有moduleの依存 | [NovelKit/Package.swift](../NovelKit/Package.swift) |
| macOS起動・画面 | [FuminiwaApp](../NovelApp/Application/FuminiwaApp.swift)、[ContentView](../NovelApp/Application/ContentView.swift) |
| macOS保存・作品遷移 | [AppState+SnapshotSyncV2](../NovelApp/Application/AppState+SnapshotSyncV2.swift)、[AppState+DocumentLifecycleV2](../NovelApp/Application/AppState+DocumentLifecycleV2.swift) |
| iOS作品状態・起動 | [IOSDocumentStore](../NovelAppIOS/DocumentLifecycle/IOSDocumentStore.swift)、[LifecycleV2](../NovelAppIOS/DocumentLifecycle/IOSDocumentStore+LifecycleV2.swift) |
| iOS画面 | [IOSWorkbenchViewV2](../NovelAppIOS/Features/Writing/IOSWorkbenchViewV2.swift)、[IOSProjectHomeViewV2](../NovelAppIOS/Library/IOSProjectHomeViewV2.swift) |
| 保存・同期の共通composition | [SnapshotSyncV2Runtime](../NovelKit/Sources/NovelSyncV2Runtime/SnapshotSyncV2Runtime.swift) |
| portable Import / Export | [SyncV2PortableBridge](../NovelKit/Sources/NovelSyncV2PortableBridge/SyncV2PortableBridge.swift) |
| server / 認証 | [SyncServerV2](../SyncServerV2/README.md)、[AUTH](AUTH.md) |

通常のlocal authorityはv2 SQLite。D-090で旧共有module・server・除外画面を削除した。今回の整理結果は[CLEANUP_20260912](CLEANUP_20260912.md)。

## 2. いま確認できること

- v2のstore / domain / application / runtime / portable bridge、Rust server、Apple認証のsourceがある。
- macOSは既存Workbenchへ接続され、iOSも作品棚→ホーム→主要7機能とregular幅のsplit表示を持つ。「v2は診断shellだけ」という過去の報告を全画面に一般化しない。
- 一方、iOSの執筆補助・promptの呼出、共通chrome、履歴・復元の製品UIには残件がある。詳細は[IOS](IOS.md)。
- 新規作品のcheckpoint時にactive account bindingを得るコードはある。認証済み新規作品がlocal-onlyのままという8月18日の実機報告は未解決として再現・切り分けが必要で、bindingの全面未実装とは断定しない。
- Auth wireはv1、Syncはv2。旧Auth文書の「全て未実装」や旧v2文書の「設計だけ」は現状と一致しない。

## 3. 既知の問題と次の作業

| 対象 | 残る作業・完了の証拠 |
| --- | --- |
| iOSの製品UI | 既存の入力・navigation・コピー導線をv2に接続し、診断用ID入力や保存内部の説明を製品操作へ置き換える。署名済み実機で受け入れる |
| 認証済み新規作品の同期 | local commitからbinding / sealed command / worker / remote head read-backまで再現し、accountを越えずに同期済みへ進むことを示す |
| D-076構造Gate | 診断ログを`IOSAuthenticationDiagnostics.swift`へ分離し、今回の構造Gateは成功。関係するiOS appテストも成功。全体Gateには別の環境・lint制約が残る |
| Apple通知endpoint | [通知契約](auth/v1/apple-notification.md)とRust routeが不一致。契約・実装・検証の整合を回復する |
| staging CA取得 | export scriptの固定edge名とrole-split構成が不一致。Sync epochの検証も含め[staging手順](SNAPSHOT_SYNC_V2_STAGING.md)の残件を解消する |
| 公開運用 | auth / syncのcredential境界、backup / restore、account lifecycle、配布・実機Gateを確認する。設計と実装の差は[AUTH](AUTH.md) / [v2引き継ぎ](SNAPSHOT_SYNC_V2_HANDOFF.md)参照 |

詳細な再現入口と受入項目は[v2引き継ぎ](SNAPSHOT_SYNC_V2_HANDOFF.md)へ集約する。未完了の実装をドキュメント変更で完了にしない。

## 4. 検証の選び方

D-086により、編集内容に応じて**検証なし／軽い／中ぐらい／重たい**を選ぶ。段階の定義と例は[AGENTS](../AGENTS.md)に集約する。マージ前の一律全通しは廃止し、選択した段階の結果で判断する。関係しない既存のコード失敗を、文書変更の完了条件にしない。

重たい検証では[Scripts/check.sh](../Scripts/check.sh)を使う。v2 conformance、構造・依存、format / lint、Swift package、macOS、iOS compile / Simulatorを含む。conformanceのローカル入口は実PostgreSQL用のopt-in URLを除き、実DB検証を明示SKIPする。全体成功も実DB・LAN・実機・公開の成功を意味しない。

## 5. 文書改訂時の記録

4段階検証・account lifecycle・Windows方針を反映した今回の追記は、利用者指定により**検証なし**。下表は先行する全面整理（`78c638fa5`）で行った確認の保存であり、この追記で再実行していない。

2026-09-12の先行確認:

| 確認 | 結果・限界 |
| --- | --- |
| target / dependency / 主要callsite | source照合済み。UIの実機受入は実施していない |
| Markdown参照と保全 | 71文書の内部リンク642件に欠損なし。全面改訂した11文書の旧本文保持と、Sync v1凍結資料の無変更を確認 |
| `Scripts/check-sync-legacy-inventory.sh` | 旧source inventory 31件を保持。文書から読み取る形式は有効 |
| `Scripts/check-code-structure.sh` | exit 1。iOS認証ファイル822行の上限超過を確認 |
| `python3 Scripts/conformance-v2.py` | 60 vectors成功。Swift / Rust全体と実DBは今回未実施 |
| 全体`Scripts/check.sh` | 今回未実施。構造Gateに既知失敗があり、全体成功とは記載しない |
| staging / 署名済みMac・iPhone | 今回未接続・未実施。8月18日の実機認証記録はhandoffの履歴 |

## 6. 履歴・移行資料の扱い

旧sourceはD-090で削除しGit履歴で保持する。凍結`docs/sync/v1/`と旧UIの完了記録は比較・説明のために保持する。履歴のチェックボックスを現在の作業一覧へ戻さない。過去の「旧データは不要」という方針は、現行DB・原稿・退避フォルダの包括削除を意味しない。削除を依頼されたときはexact targetを切り分ける。

## 7. GitHubと作業ブランチ

この改訂の開始時、local `main`は保存済み`origin/main`参照の祖先（0 ahead / 16 behind）で、`origin/main`のtreeにもiOS / 旧同期sourceがあった。「iOS未掲載」「mainの履歴が分岐」の旧説明は更新した。開始時のv2 branchと`origin/codex/snapshot-sync-v2`は同じ`32e60bdf6`だった。**fetchはしておらず、これは保存済みremote参照の確認である。**

今回の文書作業はそのv2 tipから`codex/docs-current-guidance-20260912`を作成した。自動でmainへ戻したり、現行v2の変更を古い土台へ移したりしない。

GitHubへの掲載依頼があるときは、remoteの実態・PR対象branch・差分・公開範囲を確認してからpush / PR / mergeする。旧catch-up手順を無条件に実行しない。今回の依頼は文書改訂であり、GitHubへの反映やデプロイは含まない。
