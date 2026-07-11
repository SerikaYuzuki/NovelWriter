# UI Fix 実行計画: 執筆密度・章／話階層・Workbench操作

**状態: UI-FIX-1 / UI-FIX-2a / UI-FIX-2b / UI-FIX-2c / UI-FIX-3 / UI-FIX-4 / UI-FIX-5 完了。後続のUI-REF-1〜6も完了し、Phase 5-1へ進む。**

本書は、Toolbar-2 完了後に確認された UI 修正と、「章」と「話」を分離する原稿構造の改訂を実装するための作業指示書である。前提は [../AGENTS.md](../AGENTS.md)、設計は [DESIGN.md](DESIGN.md)、決定記録は [DECISIONS.md](DECISIONS.md)、デザイン言語は [STYLE.md](STYLE.md)、現行 toolbar の設計は [TOOLBAR.md](TOOLBAR.md) とする。

Phase 5 の旧出力仕様は `Chapter` が本文を直接持つ前提だった。章／話階層を出力実装後に導入すると全レンダラとテストを作り直すため、本計画を Phase 5-1 より先に完了し、出力仕様も [PHASE5.md](PHASE5.md) で更新済みである。

## 1. 対象要望と設計結果

| 要望 | 現状の原因 | 設計結果 |
| --- | --- | --- |
| 執筆画面の上下左右の余白を縮める | `EditorView` 外側の `.padding()`、`NSTextView` の 32 / 24pt inset、本文最大幅 900pt が重複 | 外側 padding を撤去し、本文 inset を左右 16pt / 上下 16pt にする。最大幅の未設定時既定を「制限なし」へ変更 |
| 章メモをアイコン位置から表示し、再クリックで閉じる | `.popover` が toolbar item ではなく `NovelWorkbenchView` ルートに付いている | popover を toolbar item 内のボタンへ付け、同じ binding の toggle で開閉 |
| スナップショットアイコンから一覧を出す | toolbar item が保存実行専用で、一覧は File メニューだけ | アイコンを anchored popover にし、「今すぐ保存」+ 一覧 + Finder表示 + 確認付き復元を集約 |
| プロットカードの内容を popup で見る | 現在は `Menu` の項目を押すと即座にプロット画面へ移動 | 選択章のカードを popover で一覧・内容表示し、「プロットカードへ移動」で明示的に遷移 |
| 登場人物の名前を一番上に置く | 色操作と名前が同じ header 行にあり、色が先頭 | 1行目を名前、2行目をふりがな + 色に固定 |
| 章と話を分離する | `Chapter` がタイトル・本文・メモを直接所有 | `Chapter` は話を束ねる構造、`Episode` はタイトル・本文・メモを持つ編集単位に変更 |
| 執筆 Outline を章区切り + 所属する話にする | Outline が `chapters` の単層リスト | 章 header + 話 row の階層表示。追加 toolbar は「章を追加」「選択章に話を追加」の menu |
| プロット Outline に章選択を置き、伏線を右側へ移す | content 列が伏線、detail が全章レーン | content 列を章 Outline、detail を `HSplitView` の「選択章のプロット / 伏線」に変更 |
| 人物・プロット Outline を他セクションと統一 | Character は下部ボタン付き、Plot は伏線一覧で、共通の sidebar list 規約から外れる | `List(selection:)` + `.listStyle(.sidebar)` + 共通 row / 空状態 / context menu に統一 |
| フォントを 8pt まで選べるようにする | Slider が 12...24 | 8...24、1pt刻み。保存値も 8...24 に正規化 |

## 2. 原稿モデルの確定仕様

### 2.1 モデル

```text
NovelDocument
└── chapters: [Chapter]                 // 章順の唯一の正
    ├── id: ChapterID
    ├── title: String
    └── episodes: [Episode]             // 章内の話順の唯一の正
        ├── id: EpisodeID
        ├── title: String
        ├── content: String
        └── memo: String
```

- `Chapter` は本文を持たない。章は構造・区切りである
- `Episode` がエディタへ渡す本文とメモを持つ
- `order` フィールドは章にも話にも追加しない。順序は配列順だけを正とする
- `PlotCard.chapterID`、`Flag.plantedChapterID`、`Flag.resolvedChapterID` は章単位の参照として維持する
- プロットカードを話へ直接紐付ける `episodeID` は今回追加しない。選択章の構成をカードで扱う
- 現行の章メモは v1 / v2 → v3 移行時に生成される話のメモへ移す。階層化後の toolbar 文言は「話メモ」とする。章自体のメモは今回追加しない
- 新規作品(`newDocument`)は「第1章 + タイトル『本文』の話1件」で始め、すぐ編集できる状態を維持する
- 「章を追加」は空の章を追加する。話が無い章では editor を空文字で偽装せず、話追加を促す `ContentUnavailableView` を出す
- 「選択中の章に話を追加」は空の話を追加して選択する。既定タイトルは「第N話」(N はその章内の通し番号)

### 2.2 `.novelpkg` v3

```text
MyNovel.novelpkg/
├── manifest.json
├── episodes/
│   └── <EpisodeID>.md
├── episode-notes/
│   └── <EpisodeID>.md
├── characters.json
├── plot.json
├── flags.json
├── attachments/
└── snapshots/
```

`manifest.json` が章順と各章内の話順を持つ。本文ファイル名は `EpisodeID` ベースとし、並べ替えでリネームしない。

v3 の `manifest.json` 形(フィールド名は実装でこのキーを正とする):

```json
{
  "formatVersion": "3",
  "documentID": "<UUID>",
  "title": "作品タイトル",
  "chapters": [
    {
      "id": "<ChapterUUID>",
      "title": "第1章",
      "episodes": [
        { "id": "<EpisodeUUID>", "title": "本文" }
      ]
    }
  ],
  "createdAt": "<ISO8601>",
  "updatedAt": "<ISO8601>"
}
```

- `chapters[].episodes[]` の配列順が話順の唯一の正
- 本文は `episodes/<EpisodeUUID>.md`、メモは `episode-notes/<EpisodeUUID>.md`(空メモはファイルなし)
- 未対応の `formatVersion` "4" 以上は読み込みエラーとする

### 2.3 v1 / v2 からの移行

- v1 / v2 の各 `Chapter` は、同じ `ChapterID` と章タイトルを持つ新しい `Chapter` へ移す
- 旧章の本文・メモから、その章に属するタイトル「本文」の `Episode` を1件生成する
- `PlotCard` と `Flag` の `ChapterID` は変えない
- 読み込みは v1 / v2 / v3、保存は v3 とする。旧形式は次回保存で移行する
- `chapters/` と `notes/` は旧形式の既知項目として扱い、v3 保存時に未知項目として重複保持しない
- v2 スナップショットの一覧・復元、v3 作品から v2 スナップショットへ戻す経路を回帰テストする

## 3. 選択状態とテキスト所有権

AppState の選択は次へ分ける。

```swift
private(set) var selectedChapterID: ChapterID?
private(set) var selectedEpisodeID: EpisodeID?
```

- `selectedEpisodeID` は `selectedChapterID` の章に属する話だけを許可する
- 章を選ぶと、その章で最後に選んだ話、なければ先頭の話を選ぶ
- 空の章では editor を空文字で偽装せず、話を追加する `ContentUnavailableView` を出す
- `EditorView.chapterKey` 相当には `EpisodeID` を渡す。話切り替え時だけ本文を流し込み、同じ話の編集中は外から `textView.string` を変更しない
- 検索・文字数・登場箇所検出は `Episode` を編集単位として更新する(登場箇所のジャンプ先は該当話 + 範囲)
- PlotCard / Flag の章ジャンプは章単位のまま維持し、ジャンプ先はその章で最後に選んだ話(なければ先頭の話)とする

## 4. 画面仕様

### 4.1 執筆 Outline

```text
第1章                         2話 / 4,820字
  第1話                       2,100字
  第2話                       2,720字
第2章                         1話 / 1,950字
  本文                        1,950字
```

- 章は区切り header、話は選択可能な row
- 章 header の開閉状態は UI 一時状態とし、作品ファイルには保存しない
- 章・話はそれぞれ同一階層内で並べ替え可能
- 話を別章へ移す操作は、初期実装では context menu の「別の章へ移動」で提供する。階層間 drag は別改善とする
- toolbar の `+` は menu とし、「章を追加」「選択中の章に話を追加」を提供する
- 章／話の追加・削除・移動にはメニューバーまたは context menu の代替入口を必ず用意する

### 4.2 プロット

```text
content列: 章 Outline

detail列:
┌──────────────────────┬──────────────────┐
│ 選択章のプロットカード │ 伏線               │
│ 追加・並べ替え・編集    │ 未回収 / 回収済み   │
└──────────────────────┴──────────────────┘
```

- content 列には「未割り当て」と章一覧を置く
- 選択した章のカードだけを detail 左側へ表示する
- 新規カードは選択章へ割り当てる。「未割り当て」選択時は `chapterID == nil`
- 伏線は作品全体を扱うため detail 右側へ常設し、張った章／回収章のジャンプを維持する
- detail の左右比率はユーザーが調整できる。初期値はプロット 2 : 伏線 1

### 4.3 Toolbar popover

- popover / menu の表示元は各 `ToolbarItem` 内のコントロールにする。Workbench ルートに浮動 popover を置かない
- 同じアイコンの再クリックで閉じる
- 同時に開ける toolbar popover は1つだけ。表示状態は `WorkbenchOverlay` enum 1件で管理する
- 話メモ: 選択話のメモを編集
- スナップショット: 保存ボタン、一覧、空状態、Finder表示、確認付き復元
- プロットカード: 選択章のカード一覧、タイトル、メモ、「プロットカードへ移動」
- toolbar から項目を外しても使えるよう、File / 編集メニューと Outline context menu の fallback を維持する

### 4.4 登場人物と共通 Outline

- 登場人物 detail は1行目を名前の全幅フィールド、2行目をふりがな + 色にする
- Character / Plot / References / Section overview の content 列は、執筆 Outline と同じ sidebar list の背景、選択、row padding、空状態を使う
- content 列の下端に独自の追加・削除 bar を置かない。追加は section 対応 toolbar、削除は context menu と Delete キーで提供する
- 見た目を揃えるためだけの巨大な generic View は作らず、row metadata と list modifier の小さい共通部品に限定する

## 5. 実装サブフェーズ

すべて **1サブフェーズ = 1ブランチ = 1PR**。スタックPRは禁止し、前PRを main へマージしてから次を切る。

### UI-FIX-1: エディタ密度 + 8pt フォント

- `EditorView` 外側の汎用 padding を撤去
- macOS adapter の `textContainerInset` を左右16 / 上下16へ変更
- 幅設定が未保存の場合の既定を「制限なし」へ変更。ユーザーが明示保存した 700 / 900pt は維持
- font slider を 8...24 に変更し、UserDefaults 読み込み値を範囲内へ正規化
- STYLE.md の editor inset と本文最大幅の未設定時既定(制限なし)を実装値へ更新

**完了条件:** 8 / 16 / 24pt で日本語IME、改行、自動字下げ、Undo が動作し、800 / 1200 / 1600pt 幅で不要な二重余白がない。

### UI-FIX-2a: Chapter / Episode モデル + `.novelpkg` v3【完了】

- `EpisodeID` / `Episode` / `Chapter.episodes` を追加
- v3 manifest と episode 本文・メモの読み書きを追加
- v1 / v2 → v3 の移行を実装
- 現行 App を壊さず段階移行できる最小の互換 accessor を一時的に用意し、撤去条件をコードに明記
- Core / Storage の移行テスト、旧 snapshot 復元テストを追加

**完了条件:** v2 fixture を無損失で読み、保存後に v3 として再読込できる。本文、メモ、カード、伏線、資料、snapshot が残る。

**実装結果 (2026-07-11):** `EpisodeID` / `Episode` / `Chapter.episodes` を追加。v1 / v2 の `chapters/` + `notes/` を `EpisodeID == ChapterID` の「本文」話へ移行し、v3では `episodes/` + `episode-notes/` と nested manifest を書き出す。移行中だけ置いた章本文・章メモの互換accessorはPhase 5着手前監査で撤去した。v3の複数話順、欠損本文、旧形式移行、添付・snapshot保持をテスト済み。

### UI-FIX-2b: AppState の話選択と操作【完了】

- `selectedChapterID` / `selectedEpisodeID` を選択の正にする
- 話の追加・更新・削除・並べ替え・別章移動を AppState / NovelCore helper に追加
- Editor / search / metrics / character appearances を Episode 単位へ移す
- 新規・開く・別名保存・snapshot復元後の selection を回帰テスト

**完了条件:** 話切り替え時だけ Editor のキーが変わり、編集中のIME所有権を壊さない。章／話削除後も有効な選択へ移る。

**実装結果 (2026-07-11):** AppStateの選択正を`selectedChapterID` / `selectedEpisodeID`へ分離し、話の追加・更新・削除・並べ替え・別章移動を実装。Editor、検索、文字数、登場箇所検出をEpisode単位へ移し、新規・開く・別名保存・snapshot復元で選択を初期化する回帰テストを追加した。既存UIの章単位APIは2c移行まで互換名で維持する。

### UI-FIX-2c: 階層型の執筆 Outline + 追加 menu【完了】

- 章 header + 話 row を実装
- toolbar `+` を章／話の追加 menu に変更
- rename / delete / reorder / 別章へ移動と fallback command を接続
- 章・話それぞれの件数、文字数、保存・メモ状態を表示

**完了条件:** 複数章・複数話を作り、選択、編集、並べ替え、保存、再起動後の順序を確認できる。

**実装結果 (2026-07-11):** 執筆Outlineを章行＋話行の階層表示へ更新し、話選択時にEpisodeIDをAppStateへ渡すようにした。Toolbarの`+`を章／話追加メニューへ変更し、話タイトル編集、章内並べ替え、別章移動、削除確認、章／話ごとの件数・文字数・メモ状態を追加した。

### UI-FIX-3: プロット章 Outline + 伏線 split【完了】

- Plot の content 列を章 Outline に変更
- detail を選択章プロット / 伏線の左右 split に変更
- 追加カードの割当、未割り当て、章移動、章ジャンプを接続
- Plot / Flag の操作テストを章／話モデルへ追従

**完了条件:** Outline で章を切り替えると左側カードだけが切り替わり、右側の伏線は維持される。カードと伏線の章参照が再起動後も正しい。

**実装結果 (2026-07-11):** プロットのcontent列を「未割り当て」＋章Listへ変更し、detail列を選択対象のプロットカードと作品全体の伏線のHSplit(初期比率 2:1)へ変更した。選択に応じて未割り当てまたは選択章のカードだけを表示し、PlotCard / Flagの既存ChapterID参照と章ジャンプを維持した。

### UI-FIX-4: Toolbarの anchored popover

- `WorkbenchOverlay` で話メモ / snapshots / plot cards の排他表示を管理
- 話メモをアイコン起点で開閉
- snapshot アイコンから保存・一覧・Finder・復元を提供
- plot card の内容 popup と明示的な移動ボタンを提供
- root に付いているメモ popover と、保存だけを行う snapshot button を撤去

**完了条件:** 各 popup が押したアイコン付近に出て、同じアイコンの再クリックで閉じる。toolbar カスタマイズ後も menu fallback から全操作へ到達できる。

**実装結果 (2026-07-11):** `WorkbenchOverlayState` でメモ・スナップショット・この章の表示を排他的に管理し、各 `ToolbarItem` に直接 `.popover` を接続した。メモは話メモを編集でき、スナップショットは保存・一覧・Finder表示・確認付き復元を提供する。この章はカード内容を段階表示し、プロットカード画面へ移動できる。既存の File / Outline / CommandMenu の fallback は維持した。

### UI-FIX-5: Character header + Outline統一

- 名前を detail 最上段へ移動
- Character list の独自下部 bar を撤去し、共通 sidebar list 規約へ合わせる
- Character / Plot / References / overview に共通 row metadata / list modifier を適用
- section に応じた追加 toolbar と context menu / Delete fallback を整える

**完了条件:** セクションを切り替えても content 列の背景、row高さ、選択、空状態、追加・削除の作法が一貫する。

**実装結果 (2026-07-11):** キャラクター詳細を「名前」→「ふりがな・カラー」の順に再配置し、キャラクター一覧の下部操作バーを撤去した。Character / Plot / References / overview / 執筆Outlineで共通のsidebar List modifierと2行メタデータ表示を使い、空状態の次の一歩も統一した。登場人物・プロットカード・資料の追加をセクション別Toolbarとメニューへ移し、削除は行のcontext menuとDeleteキーの確認導線を維持した。

## 6. 各PRの検証ゲート

- `./Scripts/check.sh` が All checks passed
- 既存 `.novelpkg` v1 / v2 fixture と新 v3 fixture の読み書き
- 日本語IME変換、自動字下げ、Undo / Redo、章／話切り替え
- 自動保存、Cmd+Q、作品の新規・開く・別名保存、snapshot保存・復元
- ダーク外観とライト外観、ウィンドウ幅 800 / 1200 / 1600pt
- VoiceOver label、キーボードフォーカス、menu fallback
- STYLE.md 9章のUIチェックリスト

## 7. 非目標

- 章自体の本文・章メモ
- プロットカードと個別 Episode の直接リンク
- 階層をまたぐ drag & drop(初期版は「別の章へ移動」command)
- 複数階層の部・巻・節
- Phase 5 の書き出し実装
- AI機能、縦書き、iOS UI

## 8. Phase 5 への引き継ぎ

UI-FIX-5 完了後、PHASE5.md の出力仕様を `NovelDocument → Chapter → Episode` へ更新済みである。出力順は章配列順、その中の話配列順とし、テキスト / Markdown / EPUB / PDF のすべてで章見出しと話見出しを区別する。次は Phase 5-1(Export Core + プレーンテキスト / Markdown)へ進む。
