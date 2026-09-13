# iOS / iPadOS の製品契約と現在地

**ソース確認: 2026-09-12 / 対象: iOS・iPadOS 17以降 / Release NO-GO**

iPhone / iPadで、通信を待たず日本語小説を編集・保存する。作品棚から作品ホーム、各機能へ進む段階導線と、iPadの適応的な複数列を維持する。保存・同期の正は [Snapshot Sync v2](SNAPSHOT_SYNC_V2.md)、実機記録と次の修復は [v2 handoff](SNAPSHOT_SYNC_V2_HANDOFF.md)。本書は製品要件と現行コードの差を扱う。

## 1. 現在の実装

[`project.yml`](../project.yml) が通常targetと除外ソースの正。ディスクに旧Viewがあることを、現行画面へ接続済みという証拠にしない。

| 対象 | 2026-09-12に確認したソース | 完了と区別する点 |
| --- | --- | --- |
| 作品棚・作品ホーム | `Library/IOSLibraryViewV2.swift`、`IOSProjectHomeViewV2.swift` | ボタンとList中心。既存カードUIの品質に到達したとは扱わない |
| 段階導線・iPad複数列 | `Features/Writing/IOSWorkbenchViewV2.swift` | 執筆・作品情報・プロット・人物・世界観・資料・感想アドバイス・設定へのrouteあり。実機受入は別 |
| 本文 | 同ファイルの`IOSEditorPane`から`EditorView`へ接続 | 執筆補助バーと本文context menuのprompt操作をlive Viewへ接続済み。署名済み実機受入は未実施 |
| クリップボード支援 | `DocumentLifecycle/IOSDocumentStore+ClipboardV2.swift`と共有builder | 選択context menuと話／章toolbar menuを接続済み |
| 履歴・競合 | 作品ホームに履歴取得／復元と3択あり | 日時の履歴行から確認dialogで復元。作品／accountをまたぐ確認を拒否し、診断用ID入力を廃止 |
| 共通chrome | 旧`iosWorkChrome`の空実装と呼出を削除し、Workbenchがtoolbarを所有する | 旧画面にあるtoolbar拡張の呼出だけで同期／履歴入口の存在を主張しない |
| 外観・本文フォント | `Features/Settings/IOSSettingsViewV2.swift`、`Platform/iOS/IOSAppearance.swift` | 初回Dark、System／Light／Dark選択、端末内本文フォント設定あり |
| 保存・認証 | v2 application/store、`DocumentLifecycle`と`DeviceSync/*V2*` | SQLite checkpointとApple認証の実装あり。新規作品のremote反映とpaired実機Gateは未完了 |

2026-08-18のhandoffは、署名済みiPhoneでApple認証と再起動後のsession復元を確認した記録である。「minimal shell」という当時の評価を、全routeが存在しない意味へ広げない。一方、今回のソース確認だけで執筆UIの回帰が解消したとも扱わない。

## 2. 維持する製品スコープ

- 作品棚 → 作品ホーム → 各機能 → Outline / Detail。iPhoneは段階遷移、iPadは同じ意味を複数列へ展開する。
- 章／話の追加、選択、タイトル編集、並べ替え、本文、話メモ、検索、文字数、作品情報、人物、プロット／伏線、世界観、資料、設定。
- 本文下に`……`／`――`／`ルビ`／`傍点`の執筆補助。44pt以上の操作面、IME中の拒否、失効した選択の拒否、1回のUndoで戻せること。
- 選択／話／章のplain textコピー（D-094）。AI依頼文と用途選択は付けない。範囲と安全条件は [CLIPBOARD_AI_ASSIST.md](CLIPBOARD_AI_ASSIST.md)。D-089の別機能として、[現在の1話を明示送信するAI支援](WRITING_ASSISTANT.md)を追加した。
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

2026-09-12の今回の接続・検証結果は[作業記録](WORKBENCH_IMPLEMENTATION_20260912.md)参照。Xcode 27.0（27A5194q）のSDKでbuildし、iPhone Simulatorでappテストを実施した。最低対応OSの17は維持する。最新OSでの配布受入・iPadの全size class受入とは区別する。


まず既存の製品要件をv2へ接続する。旧Viewは表示と操作意図の参考に限り、旧package保存・CloudKit・Note同期をコピーしない。新規作品のlocal-only問題、全体検証の既知停止点、staging再検証の順序はhandoffへ集約する。

検証はD-086に従い変更の影響で選ぶ。方針記録・説明変更は「なし」、局所文言・表示等は「軽い」限定確認、単一機能は「中ぐらい」の対象testとbuild、保存・認証scope・互換・共有層へ影響する変更は「重たい」の [Scripts/check.sh](../Scripts/check.sh) 全体と関連境界検証を使う。mergeだけを理由に全体検証へ格上げしない。対象に応じてnavigation／session、IMEとUndo、local checkpoint、account隔離、clipboardの範囲を選び、build成功や過去のtest件数を実機受入の代わりにしない。今回の方針追記は検証なし。

製品としてのUI受入には、署名済みiPhone / iPadで次の記録を揃える。これは毎回の変更検証へ一律に課す手順ではない。

- 棚・ホーム・全機能の遷移、狭幅／回転／Split View、VoiceOver／Dynamic Type／hardware keyboard。
- 日本語IME中の選択・話切替・戻る操作、執筆補助のUndo、scene退避・終了・再起動後の確定本文。
- Macとの双方向同期、offline編集、単一の競合と3択、復元前保全、履歴、remote-only open、account切替。
- 変更のない保存／同期が成功扱いであり、通信不能でもlocal編集を継続できること。

Files原本のopen-in-place、共同編集、複数作品同時編集、Windows実装と旧provider研究は別スコープ。D-089のAPI支援は今回の対象。iOS受入によってPackage Validatorや公開配布Gateが完了するわけではない。

## 5. 参照と履歴

- 見た目と操作の規約: [STYLE.md](STYLE.md)。決定: [DECISIONS.md](DECISIONS.md) D-056〜058、D-075、D-080、D-084、D-086。
- 公開技術Gate: [COMMERCIALIZATION_IMPLEMENTATION.md](COMMERCIALIZATION_IMPLEMENTATION.md)。portable契約: [CROSS_PLATFORM.md](CROSS_PLATFORM.md)。
- [旧IOS-1〜6計画・CloudKit実装記録の全文](archive/product-guidance-20260912/IOS.md)。過去の「実装済み」は当時のtargetに対する記録として読む。

## 2026-09-12 作品一覧への明示入口

作品ホーム・執筆・設定など各作品画面の右上に「作品一覧」を常設する。一覧画面の見出しも「作品一覧」に統一した。ボタンはIME確定と端末保存をdocument operation gate内で完了してからnavigation pathを空にする。保存中に作品・account・経路が変わった場合は、その後の画面を一覧へ戻さない。通常の階層Backは維持する。

## 2026-09-12 作品一覧から開けない不具合

実機のView Debuggerで修正版の作品一覧が表示されていることを確認。行のtapが一律に`openRemoteOnly`を呼び、local/cached行をremote-onlyの事前条件で拒否していた。`openPrivateDocument`による既存のlocal/remote振り分けへ接続し、localではcheckpoint後にSQLiteから開く。remote-onlyの非同期取得完了時の遷移は維持する。サインアウト表示を含むlocal行選択とnavigation/sessionの14テスト成功。`worker/plan-blocked receiptMismatch`はquarantined createWorkの同期停止であり、この修正で受領検証を緩和したり実DBを修復・削除したりしない。

## 2026-09-12 Macの作品がiPhoneの一覧に出ない不具合

実機ではサーバー一覧3件の取得に成功していたが、並行する端末内projectionの更新により共通の世代が進み、正常な応答を破棄していた。サーバー一覧専用の更新世代を分離し、取得した一覧を現在の端末内行と合成する。アカウント遷移時は両方の世代を無効化し、以前のアカウントの応答は引き続き拒否する。端末内更新は通信の完了を待たない。検証は中ぐらいを選択し、更新完了順の両ケース、旧アカウント応答の拒否、既存の同期投影・アカウント遷移を含む30テストが成功。

署名済みiPhone向けビルドをXcodeから実行し、View Debuggerで作品一覧に4行が表示されることを確認した。既存の`worker/plan-blocked receiptMismatch`は引き続き記録されており、今回の一覧修正による解消対象ではない。

## 2026-09-12 執筆画面の操作整理

上記「作品一覧への明示入口」の常設ツールバーボタンは利用者方針により撤去した。通常の階層Backで戻る。

話名は、執筆画面上部の話名メニュー（タップ・長押し）と、話一覧の各行の長押しにある「話の名前を変更」から編集する。iPadの分割表示も同じ操作を使う。変更確定時に取得元の作品sessionとaccount scopeを検証し、削除済みの話や別の章へ適用しない。本文とEditorKitの編集tokenを維持してmetadataのみ通常保存する。空白だけの名前は確定できない。

執筆画面のAI支援ボタンは、アクセント色のsparklesアイコンと「AI」の表示に変更した。

## 2026-09-12 作品一覧での作品名変更

作品行を長押しし、「作品名を変更」から名前を編集できる。空白だけの名前は確定できない。名前変更中は対象行に進行表示を出す。端末内の作品は通信を待たずSQLiteへ保存し、サーバーのみの作品は明示操作に必要なデータを取得してから変更する。作品やアカウントが切り替わった場合は古い確認を適用しない。編集中の入力を先に保存し、一覧から別作品の名前を変更しても選択中の作品・話やEditorの内容世代は変えない。

2026-09-13: 作品ホーム／iPad左sidebarに「感想・アドバイス」を追加。日時付きの読み取り専用Markdownを一覧・詳細で読み、長押しから確認後に削除する。保存／削除は既存attachment checkpointを通じ作品と同期する。回答取得時のsession／accountを保存まで保持する。形式は[AI feedback attachments](sync/v2/assistant-feedback.md)。
