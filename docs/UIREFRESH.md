# Workbench 透明感・余白・セクション構成の再設計

**状態: UI-REF-1〜6完了。次は Phase 5-1(Export Core + プレーンテキスト / Markdown)。**

本書は、UI-REV-1〜9完了後に確認された手触り・導線の不足を、Phase 5(出力)へ入る前に解消するための作業指示書である。完了記録の正は本書、前段の再設計は [UIREVISION.md](UIREVISION.md)、見た目は [STYLE.md](STYLE.md)、決定は [DECISIONS.md](DECISIONS.md) D-032 とする。

すべて **1サブフェーズ = 1ブランチ = 1PR**。スタックPRは禁止する。

## 1. 修正する認識

| 対象 | 現在の方向違い | 正しい方向 |
| --- | --- | --- |
| 透明感 | Outlineだけが`.thinMaterial`で、detail chromeは`.bar`や不透明面が残る | Sidebar / Outline / detail chromeをSwiftUIらしいtranslucent materialで揃え、本文キャンバスだけを不透明に保つ |
| 入力余白 | あらすじ・登場人物などのラベルと入力欄が張り付いて見える | ラベル→入力の縦8pt、入力内inset、グループ間16ptを共通部品で固定する |
| 作品情報・設定のOutline | 1行だけの「概要」Listがcontent列を占有する | Outline不要。Sidebar + Detailの2列にする |
| 世界観 | placeholderのまま永続モデルがない | 章立てのないノート一覧＋本文編集。タイトルと本文を自由に持てる |
| Phase 5前の残骸 | SectionOverviewの無駄列、Outline二重material、docsのCmd+1〜8表記ずれ | 本計画でまとめて解消する。ファイルリネーム(4.5-1c)とAIパネル本体は別扱い |

## 2. 透明感(Glass Workbench)

### 2.1 原則

- **透かす対象**: Project Sidebar、すべてのOutline、detailのchrome(見出しバー、フォーム背景、GroupBox周辺、設定Formの背面)
- **透かさない対象**: 原稿本文の`EditorView`背景、世界観ノート本文の`EditorView`背景。長文可読性のため`EditorSettings`の不透明キャンバスを維持する
- materialはmacOS標準の`.thinMaterial`を基本とする。Outlineとdetail chromeで別トークンを発明しない
- Reduce Transparency時はOS fallbackに任せ、独自の不透明色へ差し替えない
- hexの`surface` / `surfaceRaised`はカスタム描画やエディタ色の補助に限り、Workbench chromeの塗りつぶしには使わない

### 2.2 実装方針

- `workbenchGlassOutlineStyle()`を維持し、Outline系Listの正とする
- `workbenchGlassChromeStyle()`をdetail chromeとOutline pane全体の共通surfaceとする
- `SectionSurface`の見出しバーを`.bar`から`.thinMaterial`へ変更する
- `EditorAccessoryBar`も`.thinMaterial`へ寄せる(UI-REV-5の「barまたはthinMaterial」のうちthinMaterialを選ぶ)
- `ProjectInfoView`の保存情報カード、Character detailのScrollView背面、Settings埋め込み領域の背面を`.thinMaterial`またはスクロール下のwindow materialが見える構成にする
- `OutlineContainerView`外枠と内側Listの**二重`.thinMaterial`**をやめ、執筆Outlineは外枠へglass、Listは`workbenchOutlineListStyle()`だけを使う
- Plot canvas / 伏線領域のchromeも不透明な独自塗りを避け、カード自体の淡い面だけを残す

### 2.3 非目標

- ウィンドウ全体を`ultraThinMaterial`一色にすること
- ライト外観専用の別material設計(セマンティックのまま追従できればよい)
- エディタ本文背景の半透明化

## 3. 入力余白(Labeled Field)

### 3.1 共通部品

NovelAppに小さい共通Viewを置く(巨大なgeneric Formフレームワークは作らない)。

```text
WorkbenchLabeledField
  label: String
  spacing: 8pt(ラベルと入力の間)
  content: 入力コントロール
```

長文入力には`WorkbenchLabeledEditor`を置く。

```text
WorkbenchLabeledEditor
  label
  spacing 8pt
  TextEditor or bordered container
  内側 padding 8pt
  外枠 RoundedRectangle(cornerRadius: 8) + .separator
```

### 3.2 適用箇所

| 画面 | 変更 |
| --- | --- |
| 作品情報 | タイトルは縦積みラベル＋TextField。あらすじは`WorkbenchLabeledEditor` |
| 登場人物 | `labeledEditor`とヘッダーのふりがなを共通spacingへ。役割などの横並びTextFieldもラベルとの間を8pt以上空ける |
| 世界観 | タイトルTextFieldと本文Editorの間を16pt。本文はEditorKit |
| 設定 | 既存`.formStyle(.grouped)`を維持(システムが余白を持つ)。二重paddingだけ解消する |

### 3.3 STYLEへの反映

- 「ラベルと入力コントロールの間隔は8pt。長文入力は内側inset 8ptを必ず持つ」
- `LabeledContent`の横並びを長文入力に使わない。短文1行のみ横並び可

## 4. セクション列構成

### 4.1 Outlineの要否

| Section | Outline(content列) | Detail |
| --- | --- | --- |
| 執筆 | 章／話ツリー | Editor |
| プロット | 章／未割り当て | Plot + 伏線 |
| 登場人物 | 人物一覧 | 人物シート |
| 資料 | 添付一覧 | プレビュー |
| 世界観 | ノート一覧 | タイトル + 本文Editor |
| **作品情報** | **なし** | 編集カード + 保存情報 |
| **設定** | **なし** | EditorSettings |

### 4.2 2列 / 3列の切り替え

`NovelWorkbenchView`はsectionに応じて列数を切り替える。

- Outlineあり: 現行どおり Sidebar + Content + Detail
- Outlineなし(`projectInfo` / `settings`): Sidebar + Detail の2列。content列を出さない

sectionに応じて`NavigationSplitView`の2列イニシャライザと3列イニシャライザを切り替える。3列構成の`columnVisibility`ではcontentだけを隠してSidebar + Detailを残せないため、この方法には分岐しない。

空の「概要」Listはマウントせず、`SectionOverviewList`は削除する。

### 4.3 幅

- Outlineなし時、Detailはウィンドウ残り幅を広く使う。作品情報の入力maxWidth 720、設定のmaxWidth 560は維持してよい
- Sidebar幅は変更しない

## 5. 世界観ノート

### 5.1 体験

「章立てのない執筆画面」。

```text
┌ Sidebar ┬ Outline(ノート一覧) ┬ Detail ─────────────────────┐
│ 世界観   │ 魔法体系            │ タイトル [TextField]         │
│          │ 年表地図            │                             │
│          │ + ノートを追加      │ ┌ 本文(EditorView) ───────┐ │
│          │                    │ │                         │ │
│          │                    │ └─────────────────────────┘ │
└──────────┴────────────────────┴─────────────────────────────┘
```

- Outline行はタイトル + 文字数(caption)
- 追加はOutline側のpane固定`+`(登場人物と同様の作法)
- 削除はcontext menuとDeleteキー、確認付き
- 並べ替えは同一一覧内のdrag
- 空状態は`ContentUnavailableView` + 「ツールバーまたは＋からノートを追加できます」

### 5.2 モデル(NovelCore)

```swift
public struct WorldNoteID: Hashable, Codable, Sendable { ... }

public struct WorldNote: Codable, Sendable, Identifiable, Equatable {
    public var id: WorldNoteID
    public var title: String
    public var content: String
}

// NovelDocument
public var worldNotes: [WorldNote]  // 配列順が唯一の正。orderフィールドなし
```

- 選択は`AppState.selectedWorldNoteID`
- 本文所有権はD-005に合わせ、編集中の正は`NSTextView`。`didChange`でモデルへ即時反映し、自動保存要求だけを2秒デバウンスする。ノート切り替え前には最新のモデル反映と保存要求を確定し、未反映の本文を破棄しない
- EditorKitへ渡すキーは`WorldNoteID`(話の`EpisodeID`と同じく型で取り違えを防ぐ)
- 空タイトルは編集中許可。表示fallbackは「無題のノート」。commit時に空ならfallbackへ正規化してよい

### 5.3 保存(NovelStorage)

`.novelpkg` v3へのadditive metadataとし、**formatVersionは上げない**。

```text
world.json          ノート順とタイトル
world-notes/<UUID>.md   本文
```

```json
{
  "notes": [
    { "id": "…", "title": "魔法体系" }
  ]
}
```

規則はあらすじ(`project.json`)に準じる。

- NovelStorage外へパスやJSON構造を漏らさない
- `world.json` / `world-notes/`は既知項目。空一覧ならファイル・ディレクトリを省略してよい
- 旧アプリはunknown root item保持でファイルを維持できる
- snapshot / 別名保存でも本文が欠けないことをテストする
- v1 / v2読み込み後の初回保存でv3 + 空の世界観として書き出してよい

### 5.4 UIとEditor

- Detail上段: タイトル`TextField`(WorkbenchLabeledField)
- Detail下段: `EditorView`(既存のIndentPlugin / IMEGuardを流用)。世界観では自動字下げを有効のままでよい(執筆と同じ手触り)
- ルビ／傍点accessoryは世界観Editorにも出してよい(同じcommand境界)
- 話内検索は世界観では非表示(または将来ノート内検索。初期は出さない)

### 5.5 Phase 5出力との関係

世界観ノートは **Phase 5 v1の出力対象に含めない**。あらすじと同じく、将来Export optionとして別決定する。

## 6. Phase 5前に織り込む追加修正

本計画のPRに混ぜてよいもの / 別PRに残すものを分ける。

### 6.1 本計画に含める

- `SectionOverviewList`の削除と列切り替え
- Outline二重materialの解消
- STYLE / TOOLBAR / DESIGNのCmd+1〜7と「企画」残表記の修正
- 作品情報・設定のchrome透明化と余白
- 世界観のモデル・保存・UI
- D-032の実装記録更新

### 6.2 本計画に含めない(別タイミング可)

| 項目 | 理由 |
| --- | --- |
| 4.5-1cファイルリネーム | 挙動変更なしの独立chore。1PR原則を守る |
| AI Assistantの実機能 | Phase 6領域 |
| ステータスバーの行／列表示 | EditorKit座標の別設計が必要 |
| WritingInspectorView等のデッドコード全削除 | 影響調査が別PR向き。触るファイルに限定した削除は可 |
| Phase 5 Exporter実装 | 本計画完了後 |

## 7. STYLE / DESIGNへの更新要点

STYLE.md:

- 深さの章に「detail chromeも`.thinMaterial`。本文キャンバスのみ不透明」
- フォーム章にLabeled Fieldの8pt規則
- ショートカットをCmd+1〜7へ修正

DESIGN.md:

- 6章に世界観ノートの現行機能を追加
- `.novelpkg`配置に`world.json` / `world-notes/`を追記
- 11章の次タスクを本計画へ向ける

## 8. 実装サブフェーズ

### UI-REF-1: Glass chrome拡張【完了】

- `SectionSurface` / AccessoryBar / detail背面のmaterial統一
- Outline二重material解消
- STYLEの深さ・素材節を更新
- Reduce Transparencyとダーク外観の目視

**完了条件:** Outline以外のchromeも背面がわずかに見え、本文キャンバスだけが不透明。

**実装結果 (2026-07-11):** `workbenchGlassChromeStyle()`と`workbenchOutlineListStyle()`を分離し、執筆Outlineはpane全体へglass、Listは1層だけmaterialを適用した。`SectionSurface`、Editor accessory、人物詳細、資料詳細、プロットsplitのchromeもthinMaterialへ統一した。AI status barはSTYLEどおり`.bar`のまま。

### UI-REF-2: Labeled Field余白【完了】

- `WorkbenchLabeledField` / `WorkbenchLabeledEditor`を追加
- 作品情報・登場人物シートへ適用
- 設定の二重paddingを解消

**完了条件:** あらすじ・人物の長文入力でラベルと枠が張り付いて見えない。

**実装結果 (2026-07-11):** 作品情報のタイトル・あらすじ、登場人物シートの短文・長文入力へ共通部品を適用した。長文入力は内側8pt paddingとseparator枠を統一し、設定画面の`EditorSettingsView`二重paddingを解消した。

### UI-REF-3: Outlineなしセクション【完了】

- 作品情報・設定を2列化
- `SectionOverviewList`削除
- TOOLBAR / DESIGNの列方針を更新

**完了条件:** 作品情報と設定で不要なcontent列が出ない。他セクションの3列は維持。

**実装結果 (2026-07-11):** `NovelWorkbenchView`は作品情報・設定でSidebar + Detailの2列`NavigationSplitView`を構築し、それ以外のセクションでは従来の3列構成を維持するよう分岐した。世界観には専用のノート一覧Outlineを配置し、作品情報・設定の空の概要Listと関連する選択状態を削除した。

### UI-REF-4: 世界観モデル + Storage【完了】

- `WorldNote` / `WorldNoteID` / `NovelDocument.worldNotes`
- `world.json` + `world-notes/`の読み書き
- v1/v2/v3、snapshot、別名保存、空一覧省略のテスト

**完了条件:** UIなしでもrepositoryテストでノートの永続化が保証される。

**実装結果 (2026-07-11):** `WorldNoteID` / `WorldNote` を NovelCore に追加し、`world.json`（順序・タイトル）と `world-notes/<UUID>.md`（本文）を NovelStorage で読み書きする。空一覧時はファイルを省略し、v1/v2 読み込み後の v3 保存・スナップショット・別名保存をテストで担保した。UI は UI-REF-5 へ委譲。

### UI-REF-5: 世界観UI【完了】

- Outline一覧、追加／削除／並べ替え
- Detailのタイトル + `EditorView`
- AppState選択と自動保存接続
- 空状態・VoiceOver・Delete確認

**完了条件:** ノートを複数作り、本文編集・IME・Undo・再起動後の順序が保たれる。

**実装結果 (2026-07-11):** `WorldbuildingOutlineView` でノート一覧（タイトル＋文字数）、pane 固定の追加、context menu / Delete キーでの確認付き削除、drag 並べ替えを実装した。`WorldNoteDetailView` は `WorkbenchLabeledField` + `EditorView`（`WorldNoteID` キー）で本文所有権を維持し、AppState 経由で即時モデル反映とデバウンス保存を接続した。

### UI-REF-6: 文書同期と軽い掃除【完了】

- AGENTS / DESIGN / PHASE5 / UIREVISION / STYLE / TOOLBARを完了状態へ
- 本計画で不要になったoverview専用コードの削除
- Phase 5-1着手可能である旨を明記

**完了条件:** 現行機能・完了済みサブフェーズ・次タスクが各文書で一致し、overview専用のコードが残っていない。

**実装結果 (2026-07-11):** AGENTS / DESIGN / PHASE5 / UIREVISION / TOOLBAR / STYLE の状態と次タスクを同期し、現行のProject Sidebarから廃止済みの「企画」表記を除去した。作品情報・設定のoverview列、旧世界観placeholder、NotesSectionViewはUI-REF-3〜5で削除済みであることを確認し、未使用の `WritingInspectorView` を削除して資料Viewを `AttachmentModeView.swift` へ分離した。Phase 5-1へ着手可能な状態とした。

## 9. 共通検証ゲート

- `./Scripts/check.sh`がAll checks passed
- 1サブフェーズ＝1PR
- v1/v2/v3 package、snapshot、別名保存でデータ欠損がない
- 日本語IME、自動字下げ、Undo、話／ノート切り替えの本文所有権に回帰がない
- dark、Reduce Transparency、800 / 1200 / 1600pt幅
- 作品情報・設定が2列、世界観・執筆が3列
- STYLE.md 9章チェックリスト

## 10. 非目標

- 世界観ノートの章／話へのリンク
- 世界観のExport同梱
- 世界観本文の独自リッチテキスト
- PlotカードとWorldNoteの統合
- AIパネル実装
- formatVersionのメジャー上げ
