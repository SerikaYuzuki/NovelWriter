# UI修正再設計: Glass Outline・Plot再構成・執筆補助・作品情報

**状態: UI-REV-1〜9完了。次は Phase 5-1(Export Core + プレーンテキスト / Markdown)。**

本書は、UI-FIX-1〜5完了後に確認された方向違いを修正する実装指示書である。旧UI-FIXの完了記録は [UIFIX.md](UIFIX.md) に残し、本書で上書きする点だけを明示する。前提は [../AGENTS.md](../AGENTS.md)、全体設計は [DESIGN.md](DESIGN.md)、決定記録は [DECISIONS.md](DECISIONS.md)、見た目は [STYLE.md](STYLE.md) を正とする。

すべて **1サブフェーズ = 1ブランチ = 1PR** とし、スタックPRは禁止する。前PRがmainへマージされてから次のブランチを切る。

## 1. 修正する認識

| 対象 | 現在の方向違い | 正しい方向 |
| --- | --- | --- |
| Outline外観 | `.bar`を背景にした不透明なsidebarへ統一した | Project Sidebarを含むすべてのOutlineを、背面がわずかに透けるmacOS materialへ統一する |
| Plotのsplit | Plotと伏線を左右へ並べた | detail全体は上下。上にPlot、下に伏線。伏線領域だけを一覧／詳細の左右splitにする |
| Plotカード | 選択章を囲うレーン／カード群の箱を置いた | Outlineの章選択を文脈とし、上部キャンバスへカードだけを横方向に連続配置する。章の囲いは置かない |
| Plot移動 | context menu中心 | カードをPlot Outlineの章／未割り当てへdrag & dropして移動できるようにする |
| 追加操作 | 章と話の追加をEditor側の同じ`+`メニューへまとめた | `+`はOutline側で章追加専用。Editor左上の`square.and.pencil`で選択章へ話を追加する |
| 執筆補助 | 本文下部に明示的な入力補助がない | Editor直下にcompact barを置き、三点リーダー、ダッシュ、ルビ、傍点を挿入できるようにする |
| 企画 | 永続モデルのないplaceholderを残した | Project Sidebarから削除する |
| 作品情報 | 読み取り専用の状態一覧だけ | 上段に編集可能な作品タイトル・あらすじ、下段に読み取り専用の作品情報カードを置く |

## 2. Glass Outline

### 2.1 対象範囲

次のcontent列を同じglass surfaceへ揃える。

- Project Sidebar
- 執筆Outline
- Plot Outline
- Character Outline
- References Outline
- 作品情報／世界観／設定などのoverview Outline

Editor、Plot canvas、Character detailなどのdetail列は本文・カードの可読性を優先し、Outlineと同じ透過率を強制しない。

### 2.2 materialと階層

- 共通modifier名は `workbenchGlassOutlineStyle()` とする
- `List` は `.listStyle(.sidebar)` と `.scrollContentBackground(.hidden)` を維持する
- 背景は固定hexや`.bar`で塗り潰さず、macOS 14で利用可能な `.thinMaterial` を基本とする
- 背面のwindow surfaceがわずかに見える程度に留め、透明そのものにはしない
- 選択、hover、focus ringは標準`List`へ委ね、独自ハイライトを重ねない
- pane境界は`.separator`のhairlineだけを使い、常設shadowは追加しない
- Reduce Transparency有効時はOSが提供する不透明fallbackに従う

### 2.3 完了条件

- セクションを切り替えてもOutlineのmaterial、選択、row padding、空状態が同じ
- dark/lightの両方で文字が読め、Reduce Transparencyでも情報が欠けない
- 背景が完全な不透明面にならず、window surfaceが控えめに知覚できる

## 3. Plot画面

### 3.1 画面構造

```text
content列: Glass Plot Outline

detail列:
┌──────────────────────────────────────────────┐
│ Plot canvas                                  │
│ [Card 1] [Card 2] [Card 3] ... [+]          │
├──────────────────────────────────────────────┤
│ Flag list                 │ Flag detail       │
│ 未回収 / 回収済み         │ 編集・章ジャンプ   │
└───────────────────────────┴───────────────────┘
```

- detailの外側は`VSplitView`
- 上段Plot canvasの初期比率は全体の約2/3、下段伏線は約1/3
- 下段だけを`HSplitView`にし、左を伏線一覧、右を伏線詳細とする
- 最小値はPlot 320pt、伏線領域220pt、伏線一覧240pt、伏線詳細280ptを目安とする
- split位置はウィンドウ存続中はOS標準動作で保持し、初期実装では作品ファイルへ保存しない

### 3.2 Plotカード

- Outlineで選択中の章、または「未割り当て」に属するカードだけを上段へ表示する
- `PlotLaneView`の章タイトル付き囲い、レーン背景、外枠を撤去する
- `ScrollView(.horizontal)` + `LazyHStack`でカードを左から右へ連続配置する
- カード幅は260ptを基準にし、通常時のshadowは使わない
- 選択章名はOutlineが正なので、Plot canvasへ章の囲い・重複見出しを置かない
- 末尾の`+`カードまたは上段toolbarから、現在のOutline選択へカードを追加する
- カード上へのdropは同じ章内の並べ替えに使う

### 3.3 Outlineへのdrag & drop

- drag payloadは既存の`PlotCardID`を使う。保存形式へ新しいフィールドは追加しない
- drop targetは「未割り当て」と各章rowの全体
- chapter rowへのdropは `movePlotCard(id:toChapter:before:nil)` に接続する
- drop中だけtarget rowをaccentの淡いmaterialで示す。常設ハイライトは作らない
- 成功後はdrop先をOutline選択にし、移動したカードを選択状態に保つ
- 不正なID、削除済み章、自分自身への無意味なdropは拒否する
- Undo対応は初期実装の必須条件としないが、保存・再起動後の`chapterID`をテストする

### 3.4 伏線Viewの分離

現在の`FlagTrackerView`を次へ分割する。

```text
FlagSectionView
├── FlagListView
└── FlagDetailView
```

- 一覧選択の正は既存`selectedFlagID`
- 追加、削除確認、未回収／回収済みの分類は`FlagListView`
- タイトル、メモ、張った章、回収章、ジャンプは`FlagDetailView`
- Plotの変更に伴うFlagモデル／保存形式変更は行わない

## 4. 上部Toolbarの役割分離

### 4.1 Outline側

- `+`はOutline列上部にだけ置く
- 執筆Outlineでは`+`は章を1件追加する。話追加menuにはしない
- Plot／Character／Referencesでは同じ位置にsection固有の追加操作を表示する
- strictなpane位置を優先するため、D-024の「すべてをwindow toolbar内で自由移動可能」はsection追加操作に限り撤回する
- 実装はcontent列の1段headerまたは`safeAreaInset(edge: .top)`を使い、独自の2段toolbarをEditor上へ増やさない

### 4.2 Editor側

- Editor上部左端へ`Label("話を追加", systemImage: "square.and.pencil")`を置く
- クリックで選択中の章へ既定タイトル「第N話」の話を追加し、その話を選択する
- 章未選択時はdisabled、空章では有効
- 既存の話メモ、snapshot、この章、検索は同じ1段のEditor toolbarに維持する
- fallbackは章メニューの「選択中の章に話を追加」

## 5. Editor下部の執筆補助bar

### 5.1 配置

```text
┌ Editor本文 ────────────────────────────────┐
│                                             │
├─────────────────────────────────────────────┤
│ [……] [――] [ルビ…] [傍点…]                 │
└─────────────────────────────────────────────┘
```

- `EditorAccessoryBar`を本文直下、下部AI status barの上に置く
- 高さは標準controlに任せ、`.bar`または`.thinMaterial`の一段だけとする
- toolbar itemではなくEditor固有のaccessoryであり、window toolbarカスタマイズ対象にしない
- VoiceOver label、help、キーボードfocusを付ける

### 5.2 EditorKitのコマンド境界

本文の選択範囲とカーソルは`NSTextView`が正なので、SwiftUIから本文Bindingを直接書き換えない。

```swift
public enum EditorCommand: Sendable, Equatable {
    case requestSelectionSnapshot(UUID)
    case replaceSelection(id: UUID, text: String)
}

public struct EditorSelectionSnapshot: Sendable, Equatable {
    public var text: String
    public var range: NSRange
}
```

- 実際の命令配送は`EditorCommandSession`等の小さいobservable objectで行う
- selection取得要求には同じUUIDを持つ`EditorSelectionSnapshot`を返し、入力UIはsnapshot受領後にだけ開く
- 公開APIへ`NSTextView`を出さない
- `MacTextAdapter.Coordinator`がUTF-16 `selectedRange`を読み、`Range(_:in:)`で安全に変換する
- replacementは`shouldChangeText`／`textStorage`／`didChangeText`の正規経路を使い、Undoを1操作にまとめる
- `hasMarkedText`中は実行せず、確定後に再操作を促す。IME変換を暗黙確定しない
- 置換後のcaretは挿入文字列末尾へ移す

これはキー入力を自動変換するEditorPluginではなく、ユーザーが明示的に押すEditor commandとして実装する。

### 5.3 三点リーダーとダッシュ

- `……`ボタンは選択範囲を`……`で置換し、未選択ならcaretへ挿入する
- `――`ボタンも同様
- 既存選択文字列を保持して前後へ記号を足す機能ではない
- それぞれUndo 1回で元へ戻ることを統合テストする

## 6. なろう形式のルビと傍点

### 6.1 ルビ

出力形式は、親文字の文字種に依存せず確実に解釈できる次へ固定する。

```text
｜親文字《ルビ》
```

- 未選択で押す: 親文字とルビの2入力を持つsheet/popoverを開く
- 選択中に押す: 選択文字列を親文字欄へ入れた状態で開く。ルビ欄へfocusする
- 完了: 元の選択範囲を`｜親文字《ルビ》`で置換する。未選択なら取得時caret位置へ挿入する
- キャンセル: 本文を変更しない
- 親文字またはルビが空なら完了をdisabledにする
- 開いている間に本文または選択が変わった場合、保持したrangeが現在本文に適用可能か検証する。無効なら挿入せず再選択を促す
- 記号`｜《》`を入力値に許すが、自動escapeは初期版では行わない。previewで最終文字列を表示する
- Phase 5 v1の各Exporterはこの記法を通常本文としてそのまま保持し、EPUB／PDFで組版ルビへ変換しない

### 6.2 傍点

なろう形式は次へ固定する。

```text
《《対象文字列》》
```

- 未選択で押す: 対象文字列の入力画面を開く
- 選択中に押す: 選択文字列を入力済みで開く
- 完了: 元の選択範囲を`《《対象文字列》》`で置換する
- キャンセル、stale range、IME、Undoの扱いはルビと同じ

### 6.3 テスト

- UTF-16 range、日本語、絵文字、結合文字、改行を含む選択
- 未選択挿入、選択置換、キャンセル、stale range、IME変換中
- ルビ／傍点／記号挿入がUndo 1回で戻る
- 同じ話の編集中にSwiftUI updateから本文が巻き戻らない

## 7. Project Sidebarと作品情報

### 7.1 「企画」の削除

- `ProjectSection.planning`と`NotesSectionView(title: "企画")`を削除する
- 保存済みUserDefaultsが`planning`なら`projectInfo`へ移行する
- Cmd+1〜7を次へ再割当する

| Shortcut | Section |
| --- | --- |
| Cmd+1 | 作品情報 |
| Cmd+2 | 執筆 |
| Cmd+3 | プロット |
| Cmd+4 | 登場人物 |
| Cmd+5 | 世界観 |
| Cmd+6 | 資料 |
| Cmd+7 | 設定 |

### 7.2 作品メタデータ

`NovelDocument`へ`synopsis: String`を追加する。UI文言は「あらすじ」とする。

- タイトルは既存manifestの`title`を正として維持する
- あらすじは新しい`project.json`へ保存する
- `project.json`はv3に対するadditive metadataとし、formatVersionは上げない
- 旧アプリはunknown root item保持により`project.json`を保存時・別名保存・snapshotで維持できる
- `project.json`欠損時は空文字。空あらすじではファイルを省略してよい
- `project.json`は新実装では既知項目としてunknown item引き継ぎ対象から外し、あらすじを空へ戻した保存で旧内容が復活しないようにする
- NovelStorage外へ`project.json`のパスやJSON構造を漏らさない

```json
{
  "synopsis": "作品のあらすじ"
}
```

### 7.3 作品情報画面

```text
┌ 編集カード ────────────────────────────────┐
│ 作品タイトル [編集可能TextField]            │
│ あらすじ     [編集可能TextEditor]           │
└─────────────────────────────────────────────┘

┌ 読み取り専用カード ────────────────────────┐
│ 保存場所 / 保存状態 / 章数 / 話数 / 文字数  │
│ 保存形式                                    │
└─────────────────────────────────────────────┘
```

- タイトルは1行、あらすじは複数行。通常Binding更新はモデルへ反映し、保存は既存2秒debounceへ寄せる
- 空タイトルは編集中は許可し、commit時の表示fallbackは「無題の作品」。保存先ファイル名は自動変更しない
- 読み取り専用カードは`GroupBox`／material＋`LabeledContent`で構成し、TextFieldに見せない
- 話数は全章の`episodes.count`合計
- 「Finderで表示」は読み取り専用カード内の明示的なbuttonとして残してよい
- タイトル・あらすじの保存失敗は既存`saveState`へ統合する
- あらすじはPhase 5 v1の出力対象へ含めない。将来追加する場合はExport optionとして別決定にする

## 8. 実装サブフェーズ

### UI-REV-1: Glass Outline

- 共通glass modifierを追加し、全Outlineへ適用
- `.bar`への逆統一を撤去
- dark/light/Reduce Transparencyを確認

### UI-REV-2: Plot splitとflat card canvas

- detailを`VSplitView`へ変更
- 下段をFlag一覧／詳細の`HSplitView`へ分割
- PlotLaneの章囲いを撤去し、カードを横方向に連続表示

### UI-REV-3: Plot card → Outline drag & drop

- 未割り当て／章rowをdrop target化
- chapterID更新、選択追従、再起動後の保存をテスト

### UI-REV-4: Outline／Editor追加操作の分離

- Outline上の`+`を章追加専用へ変更
- Editor左上へ`square.and.pencil`の話追加を配置
- 各menu fallbackを維持

### UI-REV-5: Editor command bridge + 記号bar

- EditorKitにAppKit非公開のcommand境界を追加
- Editor下部barと`……`／`――`を実装
- IME／Undo統合テスト

### UI-REV-6: ルビ・傍点

- selection snapshotと入力UI
- なろう形式のルビ／傍点置換
- stale range、Unicode、Undoをテスト

### UI-REV-7: 「企画」削除

- ProjectSection、Sidebar、detail、shortcut、UserDefaults移行
- 保存モデル変更は混ぜない

### UI-REV-8: あらすじモデル + Storage

- NovelCoreの`synopsis`
- NovelStorageの`project.json`読み書き
- v1/v2/v3、unknown item、snapshot、別名保存を回帰テスト

### UI-REV-9: 作品情報UI【完了】

- 編集カードと読み取り専用カード
- タイトル／あらすじの保存状態と文言を接続

**実装結果 (2026-07-11):** 作品情報を上段の編集カード(タイトル TextField / あらすじTextEditor)と下段の読み取り専用保存情報カードへ分離した。更新はAppState経由で既存の2秒デバウンス保存へ接続し、空タイトルも編集中は許可する。話数は全章の`episodes.count`合計を表示する。

## 9. 共通検証ゲート

- `./Scripts/check.sh`がAll checks passed
- 1サブフェーズ＝1PR、前PRのmainマージ後に次へ進む
- v1/v2/v3 package、snapshot、別名保存でデータ欠損がない
- 日本語IME、自動字下げ、Undo / Redo、話切り替えの本文所有権に回帰がない
- dark/light、Reduce Transparency、800 / 1200 / 1600pt幅
- VoiceOver、focus、Delete、menu fallback
- STYLE.md 9章のチェックリスト

## 10. 非目標

- PlotCardとEpisodeの直接リンク
- 伏線モデルの階層変更
- ルビ／傍点のエディタ内リッチ表示
- なろう以外のルビ記法自動変換
- split位置の作品ファイル保存
- Phase 5のExporter実装
