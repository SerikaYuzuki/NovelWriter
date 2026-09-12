# iOS / iPadOS の製品契約と現在地

**ソース確認: 2026-09-12 / 対象: iOS・iPadOS 17以降 / Release NO-GO**

iPhone / iPadで、通信を待たず日本語小説を編集・保存する。作品棚から作品ホーム、各機能へ進む段階導線と、iPadの適応的な複数列を維持する。保存・同期の正は [Snapshot Sync v2](SNAPSHOT_SYNC_V2.md)、実機記録と次の修復は [v2 handoff](SNAPSHOT_SYNC_V2_HANDOFF.md)。本書は製品要件と現行コードの差を扱う。

## 1. 現在の実装

[`project.yml`](../project.yml) が通常targetと除外ソースの正。ディスクに旧Viewがあることを、現行画面へ接続済みという証拠にしない。

| 対象 | 2026-09-12に確認したソース | 完了と区別する点 |
| --- | --- | --- |
| 作品棚・作品ホーム | `Library/IOSLibraryViewV2.swift`、`IOSProjectHomeViewV2.swift` | ボタンとList中心。既存カードUIの品質に到達したとは扱わない |
| 段階導線・iPad複数列 | `Features/Writing/IOSWorkbenchViewV2.swift` | 執筆・作品情報・プロット・人物・世界観・資料・設定へのrouteあり。実機受入は別 |
| 本文 | 同ファイルの`IOSEditorPane`から`EditorView`へ接続 | 旧執筆補助バー・本文context menuのprompt操作はこのlive Viewへ未接続 |
| クリップボード支援 | `DocumentLifecycle/IOSDocumentStore+ClipboardV2.swift`と共有builder | 生成APIはあるが、選択／話／章copyの呼出箇所はtarget外の旧執筆Viewに残る |
| 履歴・競合 | 作品ホームに履歴取得／復元と3択あり | Snapshot ID入力、SQLite／WorkID説明など診断用表現が残る |
| 共通chrome | `iosWorkChrome`は現在そのままViewを返す | 旧画面にあるtoolbar拡張の呼出だけで同期／履歴入口の存在を主張しない |
| 外観・本文フォント | `Features/Settings/IOSSettingsViewV2.swift`、`Platform/iOS/IOSAppearance.swift` | 初回Dark、System／Light／Dark選択、端末内本文フォント設定あり |
| 保存・認証 | v2 application/store、`DocumentLifecycle`と`DeviceSync/*V2*` | SQLite checkpointとApple認証の実装あり。新規作品のremote反映とpaired実機Gateは未完了 |

2026-08-18のhandoffは、署名済みiPhoneでApple認証と再起動後のsession復元を確認した記録である。「minimal shell」という当時の評価を、全routeが存在しない意味へ広げない。一方、今回のソース確認だけで執筆UIの回帰が解消したとも扱わない。

## 2. 維持する製品スコープ

- 作品棚 → 作品ホーム → 各機能 → Outline / Detail。iPhoneは段階遷移、iPadは同じ意味を複数列へ展開する。
- 章／話の追加、選択、タイトル編集、並べ替え、本文、話メモ、検索、文字数、作品情報、人物、プロット／伏線、世界観、資料、設定。
- 本文下に`……`／`――`／`ルビ`／`傍点`の執筆補助。44pt以上の操作面、IME中の拒否、失効した選択の拒否、1回のUndoで戻せること。
- 校正／アドバイス×選択／話／章の明示promptコピー。範囲と安全条件は [CLIPBOARD_AI_ASSIST.md](CLIPBOARD_AI_ASSIST.md)。providerへの送信は含めない。
- 保存・同期状態は上部の小さな記号と必要時の説明。本文見出し、タイトル入力、文字数、下部status barを重複常設しない。
- 履歴と3択競合に到達でき、復元前の内容を保全する。利用者へSnapshot IDやDB操作を要求しない。
- chromeは初回Dark、以後は利用者の選択を保持する。本文キャンバスは独立した端末設定とする。

これらは維持する製品要件であり、上表で未接続とした部分まで実装完了を示すものではない。

## 3. 保存・同期・編集の境界

- SQLite v2が通常編集の唯一の正本。local checkpointを完了してからremote workerを動かし、起動・編集・遷移・退避をnetworkで待たせない。`.novelpkg`は明示Import／Export専用。
- Importは外部原本を変更せず、検証して新WorkIDへ採用する。Filesのsecurity-scoped accessは操作中だけ保持し、成功／失敗／取消の全経路で解放する。Exportでactive WorkID／sessionを変更しない。
- 本文の正は`UITextView`。SwiftUI更新から入力中本文を上書きしない。IME変換中はモデル同期と入力介入を止め、TextKit 2を維持する。
- 作品／話切替、画面・size class変更でEditorを外す前に、表示時のsessionと編集対象を固定してIME／フォームを確定し、同じdocument operation gateとlocal checkpointを使う。
- remoteはInboxへ検証保存し、session、account fence、generation、未保存変更、IMEを検査した安全な境界でだけ採用する。callbackからactive Editorへ注入しない。
- account未確認で作った作品は後のloginだけで自動採用しない。別accountの原稿を再bindせず、local編集を保持し、明示clone／Importの契約を使う。
- `DocumentGroup`／`UIDocument`による第二の保存所有者、CloudKit復活、v1 fallback、外部packageの直接編集を追加しない。

共有domain／store／worker／statusはNovelKit v2を使用し、iOS側にはcapture、navigation、IME、Files、clipboard、native UIだけを置く。型と依存の正は [Package.swift](../NovelKit/Package.swift)。UIKit型を共有domainやEditorKit公開APIへ漏らさない。

## 4. 次の修復と完了条件

まず既存の製品要件をv2へ接続する。旧Viewは表示と操作意図の参考に限り、旧package保存・CloudKit・Note同期をコピーしない。新規作品のlocal-only問題、全体検証の既知停止点、staging再検証の順序はhandoffへ集約する。

検証はD-086に従い変更の影響で選ぶ。方針記録・説明変更は「なし」、局所文言・表示等は「軽い」限定確認、単一機能は「中ぐらい」の対象testとbuild、保存・認証scope・互換・共有層へ影響する変更は「重たい」の [Scripts/check.sh](../Scripts/check.sh) 全体と関連境界検証を使う。mergeだけを理由に全体検証へ格上げしない。対象に応じてnavigation／session、IMEとUndo、local checkpoint、account隔離、clipboardの範囲を選び、build成功や過去のtest件数を実機受入の代わりにしない。今回の方針追記は検証なし。

製品としてのUI受入には、署名済みiPhone / iPadで次の記録を揃える。これは毎回の変更検証へ一律に課す手順ではない。

- 棚・ホーム・全機能の遷移、狭幅／回転／Split View、VoiceOver／Dynamic Type／hardware keyboard。
- 日本語IME中の選択・話切替・戻る操作、執筆補助のUndo、scene退避・終了・再起動後の確定本文。
- Macとの双方向同期、offline編集、単一の競合と3択、復元前保全、履歴、remote-only open、account切替。
- 変更のない保存／同期が成功扱いであり、通信不能でもlocal編集を継続できること。

Files原本のopen-in-place、共同編集、複数作品同時編集、Windows実装、provider統合は別スコープ。iOS受入によってPackage Validatorや公開配布Gateが完了するわけではない。

## 5. 参照と履歴

- 見た目と操作の規約: [STYLE.md](STYLE.md)。決定: [DECISIONS.md](DECISIONS.md) D-056〜058、D-075、D-080、D-084、D-086。
- 公開技術Gate: [COMMERCIALIZATION_IMPLEMENTATION.md](COMMERCIALIZATION_IMPLEMENTATION.md)。portable契約: [CROSS_PLATFORM.md](CROSS_PLATFORM.md)。
- [旧IOS-1〜6計画・CloudKit実装記録の全文](archive/product-guidance-20260912/IOS.md)。過去の「実装済み」は当時のtargetに対する記録として読む。
