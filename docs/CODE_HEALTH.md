# コードの現状・負債・簡素化（エージェント向け）

> **状態**: 2026-08-15 のコードレビュー。機能追加の依頼ではない。実装の正は [DESIGN.md](DESIGN.md)、決定は [DECISIONS.md](DECISIONS.md)。作業ガイドは [AGENTS.md](../AGENTS.md)。
>
> この文書は「今なにが live か」「どこが重いのか」「後でどう薄くするか」「GitHub へどう載せるか」を固定する。件数の再計測や N4 完了宣言はしない。

## 1. まず読むもの / 読まないもの

| 読む | 中身 |
| --- | --- |
| [AGENTS.md](../AGENTS.md) | 破ってはいけないルール、ワークフロー |
| [DESIGN.md](DESIGN.md) 1〜6・9・11章 | 現行契約と次タスク |
| [DECISIONS.md](DECISIONS.md) D-077／D-078 | SQLite正本、Rust Snapshot Sync、server-readable v1、Sign in with Apple、非破壊migrationの次世代契約 |
| [AUTH.md](AUTH.md) | provider-neutral AccountID、Apple adapter、FUMINIWA session、AccountFenceの実装前認証契約 |
| [SNAPSHOT_SYNC.md](SNAPSHOT_SYNC.md) | 次世代local schema責務、wire、server、Conflict、履歴、実装順、Release Gate |
| [SNAPSHOT_SYNC_HANDOFF.md](SNAPSHOT_SYNC_HANDOFF.md) | Lunaへ渡すR0成果物、module境界、state machine、PR完了条件 |
| [DEVICE_SYNC.md](DEVICE_SYNC.md) **0章／0-current章** | 0章はD-077〜D-079概要、0-currentは削除前の履歴 |
| [IOS.md](IOS.md) 1〜2章、4.5a、4.6 | iOS の現行導線 |
| [CLIPBOARD_AI_ASSIST.md](CLIPBOARD_AI_ASSIST.md) | 通常版 AI（clipboard のみ） |
| [CROSS_PLATFORM.md](CROSS_PLATFORM.md) | `.novelpkg` と W0 |

| 履歴。live 経路の仕様として読まない | |
| --- | --- |
| [DEVICE_SYNC.md](DEVICE_SYNC.md) **0-hist と 1〜15章** | D-059 Episode lease / D-061 whole-work `CKAsset` / 3-way merge |
| [AI_INTEGRATION.md](AI_INTEGRATION.md) の provider / sidecar 章 | D-075で実装を削除。旧検討の履歴 |
| [CODEX_SDK_FEASIBILITY_REPORT_2026-08-09.md](CODEX_SDK_FEASIBILITY_REPORT_2026-08-09.md) | B4-D までの研究記録 |
| [PHASE4.md](PHASE4.md) / [UIDESIGN.md](UIDESIGN.md) / [UIPOLISH.md](UIPOLISH.md) など UI 完了記録 | 完了証跡。次タスクではない |
| DESIGN.md の変更履歴に残る test 件数 | 当時の証跡。再計測せずに更新しない |

D-071本文のitem 2（裏でsend／fetch）とitem 5（package保存直後のpending登録）はD-073が破棄した。現行Note runtimeの修正はD-073とDEVICE_SYNC.md 0-currentを守る。新しい同期コードはD-077のSnapshot／HTTP境界へだけ足し、Note／Work／Episodeへ分岐を追加しない。

## 2. live 経路と履歴経路

通常Mac / iOS Appの **移行前production runtime** は`NoteSyncCoordinator`を注入する（D-071）。自動保存はpackageとdirty setまで、iCloudへ出すのは明示同期だけ（D-073）。D-077のRust server／SQLite clientは未実装であり、設計文書追加をruntime切替済みと扱わない。

D-077実装は、`NovelLocalStore`（SQLite＋CAS）、Snapshot domain、HTTP worker、Rust serverを別境界として追加する。D-079でCloudKit adapterとentitlementを削除し、CloudKit／新serverのdual-publishや旧CloudKit migrationをアプリの責務にしない。

残っているが **通常起動の正ではない**もの:

- `WorkSyncCoordinator` と `NovelApp/DeviceSync/Legacy/AppState+WorkSync.swift` / `NovelAppIOS/DeviceSync/Legacy/IOSDocumentStore+WorkSync.swift`。factory が `makeNoteSyncCoordinator == nil` のときと、旧 App test 用に残っている
- D-059 の Episode lease / CAS / holder と、D-061 の whole revision `CKAsset` / 3-way merge。`NovelSync` / `NovelSyncCloudKit` の source と CloudKit schema checklist の legacy type として残る
- 旧Experimentalのprovider UI・fake provider・Codex sidecar B1〜B4-DはD-075で削除済み。再開時は最新APIから再設計する

旧経路は履歴として残すが、通常Appの新しい分岐をこれらへ足さない。移行前CloudKit runtimeのbug fixだけをNote経路へ限定し、D-077の新しい同期・棚・衝突は独立したSnapshot／SQLite／HTTP境界へ実装する。

`usesWholeWorkDeviceSync` と `usesNoteSyncRuntime` の二重フラグは、旧経路を残したためのもの。移行前UIの修正はNote側の意味だけを使い、Work用語（revision / branch / merge / journal / lease）を画面へ出さない。D-077 UIはこの二重フラグへ第3分岐を足さず、cutover用compositionとfeature flagから新しいlocal-first状態を供給する。

## 3. いま直した方がいいこと（機能追加ではない）

優先は上から。依頼が「機能を足す」でない限り、ここから選ぶ。

1. **Mac と iOS の Device Sync 複製**
   D-076 R2でFeature／責務別ディレクトリへ移動し、R4でlocal libraryの状態／attestation／record／inventoryを `NovelKit/Sources/NovelLibrary/` へ統合した。`DeviceSyncLog` は `NovelApp/DeviceSync/Note/DeviceSyncLog.swift`。Note coordinator 組み立ては `AppleDeviceSyncServices.makeNoteSyncCoordinator` に寄せた。runtime / bindings / transport / library / edit intent のOS固有対は残っているが、共有状態機械は複製しない。UIKit / AppKit と `IOSDocumentStore` / `AppState` の呼び出し口、private root、CloudKit compositionだけを各 App に残す。CloudKit 型を NovelCore／NovelLibrary へ出さない。
2. **`AppState.swift` と CloudLibrary**
   本体はプロパティと `init` だけ。起動棚のrefresh/mergeは `NovelApp/Library/AppState+StartupLibrary.swift`、package readbackは `StartupLibraryLoader.swift`、pure row projectionは `StartupLibraryProjection.swift`、開く／新規／recoveryは `AppState+StartupLibraryOpening.swift`、document transitionは `NovelApp/DocumentLifecycle/AppState+Lifecycle.swift` と `DocumentLifecyclePermissionPolicy.swift`、章・選択は `NovelApp/Features/Writing/AppState+Outline.swift`、人物・プロット・伏線は `NovelApp/Features/ProjectInfo/AppState+ProjectFeatures.swift`、資料は `NovelApp/Features/Attachments/AppState+Attachments.swift`、保存は `NovelApp/DocumentLifecycle/AppState+Persistence.swift`、スナップショットは `NovelApp/Features/ProjectInfo/AppState+Snapshots.swift`。iOS CloudLibrary は models / refresh / open / mutations に分けた。新しい 200 行を `AppState.swift` 本体へ足さない。保存 coordinator は触らない。分割に伴い一部 stored state の setter が module-internal へ広がっているため、`private(set)` を型で回復するのは次の境界整理タスクとする。
3. **Work 経路と Note 経路の条件分岐**
   同じメソッドが `if usesNoteSyncRuntime` で二系統になっている。移行前runtimeのbug fixはNote側だけに書き、Work側は旧testが通る最小限に留める。D-077はこの条件分岐へ足さず、R1〜R6の独立module／compositionで置き換える。
4. **`.derivedData/`**
   `.gitignore` 済み。コミットしない。
5. **GitHub `origin/main` とローカル履歴の分岐**
   下の 7 章。catch-up PR を載せるまでは、iOS / Device Sync を含まない `origin/main` へ薄い機能 PR を出さない。
6. **iOS プロット／世界観／執筆一覧の上部 chrome**
   実装済み。`IOSWorkChrome` が Editor と同じ保存記号・「iCloudと同期」・スナップショットを Outline／詳細へ出す。登場人物／資料へ広げるなら同じ modifier を使う。UI は [STYLE.md](STYLE.md)。

バグ修正の依頼が無い限り、競合や CloudKit の再現調査に入らない。

## 4. 複雑化しているところ

- **3 世代の同期が同時にコンパイルされる**（Episode / Work / Note）。domain は分離されているが、App 層の flag と CloudKit catalog が交差する。
- **Development schema の catalog 発見**（`workID` query、hex prefix、`modificationDate`、engine 観測 ID、record ID fetch）。Production の `recordName` QUERYABLE が無い窓のための補助であり、完成した catalog 設計ではない。ここを「汎用検索」へ一般化しない。
- **document operation gate と `DocumentSaveCoordinator` の二重直列化**。lock 順は gate → coordinator。gate 付き public API 同士は呼ばない（D-041）。新しい「保存してから X」は既存の `saveNow()` / `saveAndSyncNow()` に寄せる。
- **chooser / Recovery / WorkSync preflight / Note conflict** が起動と編集の両方に顔を出す。新しい起動 UI を足すと、session token と IME 確定をまた破る。
- **DESIGN.md 11章と IOS.md 先頭** が、完了証跡・test 件数・次タスクを同じ段落に書いていた。件数は当時の証跡で、コードの正しさの定義ではない。

## 5. もっと簡素にできるところ（後続のリファクタ単位）

混ぜない。1 PR に 1 系統。

| 単位 | やること | やらないこと |
| --- | --- | --- |
| A. 共有 Device Sync サポート | ログと Note factory は寄せ済み。残るのは runtime / library / edit intent の対 | CloudKit 型を NovelCore へ出さない |
| B. AppState 分割 | chooser / lifecycle / outline / 保存 / スナップショットは extension 済み。残るのは Work 経路ファイル | 保存 coordinator の書き換え |
| C. Work 経路の縮小 | 通常 App の production composition は `workTransport: nil` とし、Note 経路だけを組み立てる。test／互換 factory の Work 注入は残す | `NovelSync` の Work 型削除 |
| D. catalog 発見 | コメントで「Development 窓」と明記し、Production 完了後に prefix scan を外す Decision を取る | 今すぐ query を削除して棚を壊す |
| E. 文書 | 本ファイルと DESIGN 11章を正にし、件数を本文から外す | 完了記録 MD の削除 |

リファクタ中も `.novelpkg` 内部を NovelStorage の外へ出さない。Editor の本文所有権と TextKit 2 は触らない。

## 6. 着手しないもの（依頼があっても確認する）

- B4-E、Codex / OpenRouter 実 provider、network、key、実原稿送信
- Production CloudKit schema を「完了」と書くこと。Dashboard deploy は未実施
- CloudKit tombstone、automatic adopt、open-in-place、Files 上の原本編集
- 移行前CloudKit runtimeで、自動保存のたびにiCloud send／pullを戻すこと（D-073）。D-077のSQLite commit後に別HTTP workerを起こす設計とは区別する
- clipboard prompt を provider 実行へ拡張すること（D-054）
- 価格・法務・販促（D-042）
- N4 署名済み Mac＋iPhone をコードだけで完了扱いすること
- ローカル `main` への直接 push、GitHub `main` への force push

次の実装は利用者が着手を指示した後、最終設計監査を通過したD-077／D-078のR0契約に対する独立conformance harnessから始める。sync＋auth OpenAPI／fixtureは実装の設計authorityだが、Swift／Rust／将来C#のrunnerが同じbytes／hash／typed errorを実証するまではR0実装Gate通過やProduction互換を宣言しない。R1 Snapshot domain＋SQLite／CAS、R2 Import／Export、R3 networkなしlocal product、R4 Rust sync server＋Apple verifier／FUMINIWA session、R5 Swift Apple auth／Keychain＋HTTP worker、R6 Conflict／online history、R7 migration、R8 Production hardening＋versioned account lifecycleの順とする。account作成を公開する前に、後続Decisionでアプリ内削除開始、猶予／取消／retention、Apple token revoke、remote削除完了read-backを固定・実装する。External Change / Conflict Gateはportable Import／Export境界へ残し、WindowsはW0。詳細は[SNAPSHOT_SYNC_HANDOFF.md](SNAPSHOT_SYNC_HANDOFF.md)。

## 7. GitHub へ載せる方針

### いまの分岐

2026-08-14 時点:

- `origin/main`（GitHub）は `fix: 執筆位置の下端余白と括弧ペアの字下げ解除 (#67)` まで。**iOS App、Device Sync、D-071〜D-074 は入っていない**
- ローカル `main` はそれらを含む。GitHub に対して数十コミット先行し、#67 の 1 コミットだけ遅れている
- 原因は、GitHub 側が squash PR、ローカル側が `merge:` コミットで別履歴を積み続けたこと

このまま `feat/…` を `origin/main` へ出すと、iOS も同期も無い土台に D-071 が載り、ビルドできない。逆にローカル `main` をそのまま push すると、未公開だった iOS / CloudKit / メモ型同期が一気に GitHub へ出る。

### 推奨

1. **先に #67 をローカルへ取り込む。** `main` で `git merge origin/main`（字下げ／余白の衝突だけを想定）。これをしないと GitHub の修正がローカルから消える。
2. **載せるなら 1 つの PR で追いつかせる。** iOS と Device Sync と D-071 は依存しているので、機能単位の薄い PR に切ると中間がコンパイルしない。タイトル例: 「iOS・Device Sync・メモ型同期・自動スナップショットを origin/main へ載せる」。本文で **N4 / Production schema / 出荷完了ではない** と書く。
3. **今回の載せ方を一つ選ぶ。**
   - squash: GitHub の履歴は短いが、ローカルの merge 履歴とはまた分岐する。載せる直後にローカル `main` を GitHub の tip へ合わせる必要がある。
   - merge commit: ローカルの履歴を残せるが、GitHub 上は大きい。
   どちらでもよいが、**載せたあとローカルだけで `merge:` して GitHub へ出さない運用をやめる。** 以降は AGENTS.md どおり `feat/…` → PR → `main`。
4. **載せない選択もある。** GitHub を「公開してよい subset（#67 まで）」のままにし、iOS / 同期はローカル専用、でもよい。その場合は origin へ push しない。中途半端に D-071 だけ出さない。
5. **載せないもの。** `.derivedData/`、`NovelApp 2026-…` のような Xcode 退避フォルダ、`Config/Signing.local.xcconfig`、証明書、CloudKit の本番秘密。
6. **載せたあとも** Package Validator、N4 操作者検証、Production deploy は別。PR が通っても出荷可能ではない。

### エージェントへ

GitHub へ push / PR / merge するのは、利用者が「載せて」「PR を作って」「マージして（GitHub）」と明示したときに限る。ローカル `main` への取り込みと GitHub 反映は別操作として確認する。
