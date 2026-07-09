# UI刷新 実行計画(Phase UI2: Workbench)

**状態: 完了。** UI2-1〜UI2-5 と凍結確認の軽微な調整を完了し、次は Phase 5(出力)へ進む。

GUI を「モードを切り替える画面」から、長時間の執筆・構造整理・AI支援が同じ机の上でつながる **macOS専用ワークベンチ** へ刷新する。
**実行エージェント(Codex 等)はこのファイルを現在進行中の作業指示書として使うこと。** 前提は [../AGENTS.md](../AGENTS.md)、設計は [DESIGN.md](DESIGN.md)、決定は [DECISIONS.md](DECISIONS.md)(特に D-021)。

旧 Phase UI(3モード制)は D-019 として完了済みだが、本方針で破棄する。D-019 の内容は消さず、履歴として残す。

## 設計方針(決定済み)

### 4領域ワークベンチ

常設の画面構成は以下。左から右へ「作品内の場所を選ぶ → 章/シーンを選ぶ → 書く」、下部に「状態とAI支援」を置く。

```text
┌ Project Sidebar ┬ Outline ┬ Editor / Detail ┐
│ 作品情報         │ 原稿     │ 章タイトル       │
│ 企画             │ 章       │ 検索 履歴 Preview │
│ 執筆             │ シーン   │                  │
│ プロット         │         │ 本文エディタ       │
│ 登場人物         │         │                  │
│ 世界観           │         │                  │
│ 資料             │         │                  │
│ 設定             │         │                  │
├──────────────────────────────────────────────┤
│ AI Assistant Panel / collapsed status bar     │
└──────────────────────────────────────────────┘
```

- **Project Sidebar**: 作品情報 / 企画 / 執筆 / プロット / 登場人物 / 世界観 / 資料 / 設定。アイコン + ラベル形式。幅は固定気味(初期 200pt、最小 184pt、最大 224pt)
- **Outline**: 原稿・章・シーンの一覧。タイトルを主表示にし、文字数・更新状態・メモ状態はアイコンで表示する。詳細はマウスホバーのツールチップで確認できる。ドラッグ並び替えを想定。通常は検索バーを隠し、上方向スクロールまたは Cmd+F で検索バーを表示する
- **Editor / Detail**: 本文を書くメイン領域。横幅を最も広く取り、上部に現在の章タイトル、検索、履歴、プレビュー、保存状態を置く。Project Sidebar で本文以外の領域を選んだ場合も、この領域を detail surface として使う
- **AI Assistant Panel**: VS Code のターミナル領域のように下から開閉する。閉じている時は薄いステータスバーとして表示し、保存状態、文字数、カーソル位置、AI状態、執筆モードを出す

### macOS専用・ダークテーマ・キーボード主体

- 対象は macOS 版のみ。SwiftUI をシェルにし、本文エディタは引き続き EditorKit の `NSTextView`(TextKit 2)を使う
- 既定テーマはダーク。見た目の詳細は [STYLE.md](STYLE.md) が正
- キーボード主体: Project Sidebar / Outline / Editor / AI Panel のフォーカス移動、検索、折りたたみ、パネル開閉にショートカットを用意する
- View を肥大化させない。`ContentView` は `NovelWorkbenchView` を置く薄いルートにし、実体は `ProjectSidebarView` / `OutlineView` / `EditorPaneView` / `AIAssistantPanelView` に分ける
- 将来の機能追加は Project Sidebar のセクション単位で差し込める構造にする

### 旧3モード制からの変更点

- ツールバーの segmented control による **執筆 / キャラクター / プロット** の切り替えは廃止する
- キャラクター・プロット・資料・設定は、Project Sidebar のセクションとして扱う
- 章メモ・この章のプロットカード・登場人物などの章コンテキストは、右インスペクタではなく Outline / Editor上部 / AI Panel の文脈操作へ再配置する
- `AppMode` は新規UIでは主役にしない。履歴互換のため残す場合も、新しい状態の正は `ProjectSection` と `WorkspaceSelection` に置く

## 状態管理とView階層

### AppState に持つ状態

新UIで増やす状態は、本文データの所有権(D-005)と保存経路(D-017)を壊さない範囲に限定する。

```swift
enum ProjectSection: String, CaseIterable, Codable {
    case projectInfo
    case planning
    case structure
    case plot
    case characters
    case worldbuilding
    case references
    case settings
}

struct WorkspaceSelection: Equatable, Codable {
    var section: ProjectSection
    var outlineItemID: OutlineItemID?
}

struct OutlinePresentationState: Equatable {
    var searchText: String = ""
    var isSearchVisible: Bool = false
    var pinnedSearchByKeyboard: Bool = false
}

struct AIAssistantPanelState: Equatable {
    var isExpanded: Bool = false
    var height: CGFloat = 280
    var inputText: String = ""
    var selectedTab: AIAssistantTab = .chat
}
```

- `ProjectSection`: 左サイドバーの選択。UserDefaults に永続化する
- `WorkspaceSelection`: Outline 上の選択。章は既存の `ChapterID` に写像する。シーンは将来のモデル追加まで UI 上のプレースホルダとして扱う
- `OutlinePresentationState`: 検索バーの表示・入力・スクロール連動状態。検索結果そのものは派生値にする
- `AIAssistantPanelState`: 下部パネルの開閉、高さ、入力中テキスト、表示タブ。AI通信状態は将来の AI Feature 側に分離する
- 保存状態、文字数、カーソル位置はステータス表示用の派生状態とし、保存の正は既存の revision ベース保存経路に置く

### View階層

```text
ContentView
└── NovelWorkbenchView
    ├── ProjectSidebarView
    │   └── ProjectSidebarRow
    ├── WorkspaceBodyView
    │   ├── OutlineContainerView
    │   │   ├── OutlineSearchBar
    │   │   └── OutlineView
    │   └── EditorPaneView
    │       ├── EditorTopBarView
    │       ├── EditorSearchBar
    │       └── EditorKit.EditorView
    └── AIAssistantPanelView
        ├── AssistantStatusBarView
        ├── AssistantChatView
        ├── AssistantSuggestionsView
        └── SelectionActionsView
```

- `EditorKit.EditorView` とアプリ側の `EditorPaneView` を混同しない。本文エディタの公開APIに `NSTextView` を出さないルールは維持する
- Project Sidebar の各セクションは将来的に `WorkspaceFeature` として、`outlineProvider` / `detailView` / `commands` / `statusItems` を持てる形に寄せる
- `NovelUI` には Sidebar row、Outline row、status item、panel header などの再利用部品を置く。App 固有の保存・ジャンプ処理は NovelApp 側に残す

## Phase UI2 ワークフロー

Phase UI2 は、UIの骨格差し替えと既存機能の再配置が絡むため、**1PRごとに「状態 → 骨格 → 既存機能接続 → 検証 → 文書更新」まで閉じる**。途中の見た目だけ・配線だけのPRを作らない。

### 基本単位

- **1サブフェーズ = 1ブランチ = 1PR**
- ブランチは main から切る。ブランチ名は `feat/ui2-1-workbench-shell` のように `feat/ui2-N-...` とする
- スタックPRは禁止。前のPRが main にマージされてから次に進む
- 実装指示は必ず `UI2-1` から順番に出す。途中の先行実装はしない
- 各PRでは、対象サブフェーズ外の見た目調整・リファクタ・モデル追加を混ぜない

### 各PRの標準手順

1. **事前確認**
   - [ ] `docs/DESIGN.md` / `docs/DECISIONS.md` / `docs/UIDESIGN.md` / `docs/STYLE.md` を読む
   - [ ] `git status --short` で作業ツリーを確認し、ユーザーの未コミット変更を巻き込まない
   - [ ] 対象サブフェーズの Must / 完了条件 / 非目標を確認する
   - [ ] 既存View・AppState・保存経路・テストの影響範囲を `rg` で洗う

2. **実装計画**
   - [ ] 触るファイル、追加するView、追加する状態、撤去する導線を短く列挙する
   - [ ] テキスト所有権(D-005)・保存直列化(D-017)・依存方向(9.1)に触れるリスクを明示する
   - [ ] モデル/保存形式の変更が必要になった場合は、そのPRでは止めて方針を確認する。UI2 の既定では永続モデル追加を避ける

3. **実装**
   - [ ] まず状態とView境界を作る
   - [ ] 次に既存機能を新しい導線へ接続する
   - [ ] 最後に STYLE.md に沿って余白・色・文言・キーボード導線を整える
   - [ ] `ContentView` / `EditorPaneView` / `OutlineView` / `AIAssistantPanelView` のいずれかが肥大化し始めたら、同PR内で小部品へ分ける

4. **検証**
   - [ ] `swift test` または影響範囲のテストを先に回す
   - [ ] 最後に `./Scripts/check.sh` を通す
   - [ ] UI変更PRでは、最低限の手動確認を行う: 起動、章選択、本文編集、日本語IME、自動字下げ、Undo、保存状態、該当ショートカット
   - [ ] 見た目は STYLE.md 9章のチェックリストで確認する

5. **文書更新**
   - [ ] 完了した Must のチェックボックスをこの文書で更新する
   - [ ] 実装結果が DESIGN.md / DECISIONS.md とズレた場合は、実装を直すか文書を更新するかを明示する
   - [ ] 次PRに持ち越すものは Nice to have か「次PRの先頭タスク」として残す

### サブフェーズ間ゲート

次のサブフェーズへ進んでよい条件:

- 対象サブフェーズの Must がすべて完了
- 完了条件を満たしている
- `./Scripts/check.sh` が通っている
- 既存データ(.novelpkg v2)の読み書きにリグレッションがない
- `UIDESIGN.md` のチェックボックスが実態と一致している
- PR説明に「何を移したか / 何をまだ移していないか / 手動確認結果」が書かれている

ゲートを満たせない場合:

- Must が大きすぎる場合は、サブフェーズ内で **A/B分割案を先に文書化** してから進める
- ただし A/B分割してもスタックPRにはしない。Aを main にマージしてからBを切る
- モデル追加、保存形式変更、AIプロバイダ接続が必要になった場合は UI2 の非目標に触れるため、その場で止めて別Phase/別決定に分ける

### 推奨PR分解

| 順番 | PR名の例 | 目的 | 終了時の状態 |
|---|---|---|---|
| UI2-1 | `feat/ui2-1-workbench-shell` | Workbench骨格とProject Sidebar | 左ナビでセクション選択でき、既存執筆画面が仮接続される |
| UI2-2 | `feat/ui2-2-outline-pane` | 章リストをOutlineへ移設 | Outlineで章選択・文字数表示・並び替え・検索表示ができる |
| UI2-3 | `feat/ui2-3-editor-pane` | Editor Top Barと本文領域の再設計 | Editorが主領域になり、検索/履歴/Preview/保存状態の入口が上部に揃う |
| UI2-4 | `feat/ui2-4-assistant-panel` | 下部AIパネルとステータスバー | collapsed status bar と expanded panel が開閉できる |
| UI2-5 | `feat/ui2-5-section-migration` | 既存機能のセクション再配置 | プロット/登場人物/資料/設定がProject Sidebar配下に移る |

### UI2-5 完了後の凍結確認

UI2-5 が完了したら、Phase 5(出力)へ進む前に1PR分の「凍結確認」を行うか判断する。軽微な調整で済むなら UI2-5 に含め、以下のどれかに該当する場合は `fix/ui2-workbench-freeze` として別PRにする。

- ショートカット衝突やフォーカス移動の不整合が残っている
- 旧3モード/旧インスペクタ由来の導線がコード上に残っている
- AI Assistant Panel の collapsed status bar と既存ステータス表示が二重管理になっている
- `ContentView` または主要Paneが再び肥大化している

## 進め方の共通ルール

- **1サブフェーズ = 1ブランチ = 1PR。着手順は UI2-1 → UI2-2 → UI2-3 → UI2-4 → UI2-5 厳守**
- スタックPRにしない。前の PR が main にマージされてから次のブランチを main から切る
- UI 文言は日本語。見た目は [STYLE.md](STYLE.md) に従う
- PR 前に `./Scripts/check.sh` 全通過。モデル・保存層の変更にはテスト必須
- 既存機能(IME、自動字下げ、検索ジャンプ、スナップショット、終了前保存、資料添付)を壊さない
- 完了時にこの文書のチェックボックスと DESIGN.md 11章を更新する

---

## UI2-1: Workbench骨格 + Project Sidebar 【必須・最初】

3モード制を置き換える土台を作る。本文編集の挙動は変えない。

### Must

- [x] `ContentView` を `NovelWorkbenchView` を呼ぶ薄いルートへ再整理する
- [x] `ProjectSection` と `WorkspaceSelection` を AppState に追加し、選択中セクションを UserDefaults に保存する
- [x] `ProjectSidebarView` を追加する
  - [x] 項目: 作品情報 / 企画 / 執筆 / プロット / 登場人物 / 世界観 / 資料 / 設定
  - [x] アイコン + ラベル形式
  - [x] 幅は固定気味(初期 200pt、最小 184pt、最大 224pt)
- [x] 旧ツールバーのモード切替 segmented control を撤去する
- [x] 既存の執筆画面は、Project Sidebar の「執筆」または「作品情報」選択時の detail として表示できるように仮接続する
- [x] ショートカット: Cmd+1〜8 で Project Sidebar の各項目へ移動

### 完了条件

Project Sidebar から各セクションを選べる。本文編集、章選択、保存が旧UIと同等に動く。check.sh 全通過。

---

## UI2-2: Outline刷新 【必須・完了】

中央左の Outline を、章リストから「原稿・章・シーンの構造を扱うペイン」へ育てる。

### Must

- [x] `OutlineView` / `OutlineContainerView` を追加する
- [x] 行表示を「タイトル + アイコン化したメタ情報」にする
  - [x] タイトルは1行
  - [x] 文字数はアイコン表示にし、ツールチップで数値を確認できる
  - [x] 更新状態はアイコン表示にし、保存済み / 編集中 / 未保存 / 競合なしの範囲で既存状態から表現する
  - [x] メモ状態はアイコン表示にし、ツールチップで有無を確認できる
- [x] 章のドラッグ並び替えを Outline 上に移設する
- [x] シーン行は将来対応として UI 型だけ用意し、永続モデル追加は別PRに分ける
- [x] 上方向スクロール時だけ検索バーを表示する
  - [x] 通常時は検索バー高さ 0 で、一覧領域を最大化する
  - [x] Cmd+F では検索バーをピン留め表示する
  - [x] Esc で検索を閉じる
- [x] Project Sidebar の選択に応じて Outline の中身を切り替えられる拡張点を用意する

### Nice to have

- [ ] 章ごとの紐付くプロットカード数、登場人物数の小さなインジケータ
- [ ] Outline 内のキーボード操作(Enter=タイトル編集、Delete=削除確認、Option+↑/↓=移動)

### 完了条件

章一覧が Outline として機能し、検索バーが通常時に隠れ、スクロール/ショートカットで出る。ドラッグ並び替えが既存保存経路で安全に保存される。

---

## UI2-3: Editor Pane刷新 【必須】

中央右の Editor を、長時間執筆向けの主役領域として作り直す。

### Must

- [x] `EditorPaneView` を追加し、上部に `EditorTopBarView` を置く
- [x] Top Bar に以下を配置する
  - [x] 現在の章タイトル
  - [x] 章内検索の入口
  - [x] 履歴(スナップショット/最近のジャンプ履歴の入口。初期はメニューだけでも可)
  - [x] プレビュー入口
  - [x] 保存状態
- [x] 本文領域は横幅を最も広く取り、既存の `EditorConfiguration` を使って余白・最大幅・行間を調整できるようにする
- [x] 長時間執筆向けに、既定の本文余白と行間を STYLE.md に合わせる
- [x] 自動保存、自動字下げ、Undo、IME所有権ルール(D-005)を維持する
- [x] ルビ対応予定のため、EditorKit 側に直接UIを足さず、将来の `RubyPlugin` / 表示設定の差し込み点をメモする

### Nice to have

- [ ] Preview は初期実装ではポップオーバーまたは右ペイン相当の仮表示でよい
- [ ] 履歴メニューにスナップショット一覧を出す

### 完了条件

Editor が最も広い領域を取り、上部操作と本文執筆が分離されている。既存のエディタ統合テストが通り、手動で日本語IME・自動字下げ・Undo を確認できる。

---

## UI2-4: AI Assistant Panel + Status Bar 【必須】

下部に、閉じるとステータスバー、開くとAI支援パネルになる領域を作る。

### Must

- [x] `AIAssistantPanelState` を追加する
- [x] `AIAssistantPanelView` を追加する
  - [x] collapsed: 28pt 前後の薄いステータスバー
  - [x] expanded: 240〜360pt、ドラッグで高さ変更
  - [x] ショートカットで開閉(Cmd+J など。既存ショートカットと衝突しないこと)
- [x] collapsed 状態で表示する情報
  - [x] 保存状態
  - [x] 選択章の文字数 / 全体文字数
  - [x] カーソル位置(行・列。取得できない間は非表示でよい)
  - [x] AI状態(未接続 / 待機中 / 実行中 / エラー)
  - [x] 執筆モード(通常 / 集中 / 校正など。初期は通常固定でよい)
- [x] expanded 状態で表示する領域
  - [x] チャット入力欄
  - [x] 提案一覧
  - [x] 選択中テキストへの操作ボタン(言い換え / 要約 / 矛盾確認 / 伏線確認など。初期は disabled 可)
- [x] AI処理は本文編集をブロックしない。本文反映は必ずユーザー確認後にする

### Nice to have

- [ ] 選択中テキストがない場合の空状態
- [ ] AI提案をプロットカード・伏線・章メモへ送る導線

### 完了条件

下部パネルが開閉でき、閉じている時もステータスバーとして使える。AI通信の本実装がなくても、状態管理とView階層が将来拡張できる形になっている。

---

## UI2-5: セクション機能の再配置とプラグイン拡張点 【必須】

Project Sidebar の各セクションへ既存機能を移し、将来機能を差し込める構造にする。

### Must

- [x] 作品情報: 作品タイトル、保存場所、formatVersion、最終保存状態
- [x] 企画: 企画メモ、ログライン、テーマなどのプレースホルダ(永続モデル追加は別PR可)
- [x] 執筆: Outline + Editor を本文執筆の主導線にする
- [x] プロット: 既存プロットカードと伏線トラッカーを Project Sidebar セクションへ移設する
- [x] 登場人物: 既存キャラクターシートを Project Sidebar セクションへ移設する
- [x] 世界観: 世界観メモのプレースホルダ。保存モデル追加は別PRに分ける
- [x] 資料: 既存資料添付機能を Project Sidebar セクションへ移設する
- [x] 設定: 既存 Settings scene と矛盾しない、画面内設定入口を用意する
- [x] `WorkspaceFeature` 相当の拡張点を設計する
  - [x] section
  - [x] outline items
  - [x] detail surface
  - [x] commands
  - [x] status items

### 完了条件

旧3モード制と右インスペクタ前提の導線が撤去され、Project Sidebar から主要機能へ到達できる。既存データ(.novelpkg v2)が欠損なく読み書きできる。

---

## 非目標(この刷新ではやらない)

- AIプロバイダ接続・課金・APIキー管理の本実装
- AIによる本文の自動書き換え
- シーン永続モデルの本格追加(Outline のUI準備まで)
- 世界観モデルの本格追加(プレースホルダまで)
- 複数ウィンドウ、複数作品同時編集
- iOS / iPadOS UI
- 縦書き(D-012)

## 全体の完了条件

- UI2-1〜UI2-5 がすべて完了している
- `ContentView` が薄いルートになり、主要Viewが `ProjectSidebarView` / `OutlineView` / `EditorPaneView` / `AIAssistantPanelView` に分割されている
- Project Sidebar、Outline、Editor、AI Assistant Panel の4領域が常設構造として成立している
- 旧3モード segmented control と右インスペクタ中心の導線が撤去されている
- 既存機能(IME・自動インデント・検索・スナップショット・終了前保存・添付)にリグレッションがない
- STYLE.md のチェックリストと `./Scripts/check.sh` が通っている
- この文書のチェックボックスと DESIGN.md 11章が実態と一致している
