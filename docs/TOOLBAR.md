# Workbench 上部ツールバー設計

> **次の修正**: toolbar item 起点の popover、スナップショット一覧、プロットカード内容表示、および Chapter / Episode 階層後の「話メモ」への移行は [UIFIX.md](UIFIX.md) を正とする。本書は Toolbar-1 / Toolbar-2 の基盤とカスタマイズ方針を引き続き保持する。

**状態: Toolbar-1 / Toolbar-2 完了。** 上部 chrome の刷新は完了。次の実装はユーザー指示に従う。

本書は、Project Sidebar / Outline / Editor の上部を、macOS の「メモ」に近い一体型ツールバーへ再構成する設計書である。全体方針は [DESIGN.md](DESIGN.md)、決定は [DECISIONS.md](DECISIONS.md) D-024、見た目は [STYLE.md](STYLE.md) を正とする。

## 1. 目的

- ウィンドウ最上部を一段にまとめ、本文領域の縦幅を増やす
- Project Sidebar / Outline / Editor の役割を、上部の情報と操作から直感的に把握できるようにする
- 章追加、章メモ、スナップショット、章内検索など、執筆中に頻繁に使う操作を近くへ置く
- macOS 標準のツールバーカスタマイズを使い、編集操作をユーザーごとに並べ替え・追加・削除できるようにする

この刷新で、現在の `EditorTopBarView` と、その下へ展開する2段目の `SearchBar` は廃止する。保存状態は下部の collapsed status bar、選択中の章名は Outline の選択行を正とし、上部で重複表示しない。

## 2. 既定レイアウト

```text
┌ Project Sidebar ┬ Outline ┬ Editor / Detail ──────────────────────────────┐
│ [Sidebar切替]    │ 作品名   │ [章を追加]   [章メモ][履歴][この章]   [章内を検索      ] │
│                  │ 12章     │                                                   │
└──────────────────┴──────────┴───────────────────────────────────────────────────┘
```

図は**初期配置**を示す。ユーザーが編集操作を並べ替えた後も、Sidebar 切替、Outline の作品情報、右端の検索は構造上のアンカーとして残す。

macOS が toolbar item の厳密な座標を決めるため、「各ペインの意味的な領域に載ること」を要件とし、参照画像とのピクセル単位の一致は求めない。特に macOS 14 では作品名 + 章数が Outline の上へ収まることを実機確認し、ずれた場合も AppKit bridge ではなく `navigationTitle` / `navigationSubtitle` の標準配置を優先する。

### Project Sidebar 上部

- macOS 標準の Sidebar 表示／非表示ボタンを置く
- ボタンは Project Sidebar の復帰手段なので削除不可とする
- メニューバーの「表示」からも同じ操作へ到達できるようにする
- 独自の開閉アニメーションや独自アイコンは作らず、`NavigationSplitView` の標準挙動を使う

### Outline 上部

- 1行目: 現在の作品名。長い場合は1行で末尾省略する
- 2行目: `12章` の形式で章数を表示する。数値は `.monospacedDigit()` を使う
- 作品名と章数は現在地を示す固定情報であり、カスタマイズ対象にしない
- 作品タイトルが空の場合は、モデルを変更せず表示だけ `無題の作品` とする

### Editor 上部

- 一段だけの操作列とし、本文の上に独自バーや展開式検索行を追加しない
- 既定では左から「章を追加」、章コンテキスト操作、右端の章内検索の順に置く
- 操作はアイコン中心とし、アクセシビリティラベルと `.help` を必ず付ける
- ボタンの背景、角丸、影は独自に作らず、ネイティブ toolbar の外観へ委ねる

## 3. ツールバー項目

| ID | 表示名 | 既定 | カスタマイズ | 動作 |
| --- | --- | --- | --- | --- |
| System sidebar toggle | Sidebarを表示／非表示 | 表示 | 固定 | Project Sidebar を開閉 |
| Outline identity | 作品名 + `N章` | 表示 | 固定 | 情報表示のみ |
| `workbench.chapter.add` | 章を追加 | 表示 | 移動・削除可 | `AppState.addChapter()` |
| `workbench.chapter.memo` | 章メモ | 表示 | 移動・削除可 | 選択章のメモを popover で編集 |
| `workbench.snapshot.save` | スナップショットを保存 | 表示 | 移動・削除可 | `AppState.createSnapshot()` |
| `workbench.chapter.context` | この章 | 表示 | 移動・削除可 | 紐付くカード・登場人物へのメニュー |
| `workbench.preview` | プレビュー | 未実装中は非表示 | 実装後に移動・削除可 | 将来のプレビュー |
| `workbench.ai.toggle` | AI Assistant | 初期非表示 | 追加・移動・削除可 | 下部AIパネルを開閉 |
| Editor search | 章内を検索 | 表示 | 右端固定 | 選択章の本文検索 |

`ToolbarItem` の ID はリリースをまたいで不変にする。作品名、章ID、配列位置などの動的な値を ID に使わない。既定配置を意図的に破棄する場合だけ、toolbar 全体の ID を `novelwriter.workbench.v2` のように版上げする。

## 4. カスタマイズ方針

macOS 14 で利用できる SwiftUI の `.toolbar(id:)` と個別の `ToolbarItem(id:)` を使う。

- 編集操作は既定の customization behavior とし、ユーザーが追加・削除・並べ替えできるようにする
- Sidebar 切替と Outline identity は構造を保つため固定する
- 検索は `.searchable(..., placement: .toolbar)` による標準の右端配置・フォーカス挙動を優先し、v1 では固定する
- 「自由な並べ替え」は、macOS 標準のカスタマイズ領域内での移動を意味する。任意座標への配置ではない
- 全項目の自由移動と、各項目を常に特定ペインの真上へ固定することは両立しない。固定アンカーと編集操作を分けることで解決する
- 各操作を独立して消せるよう、複数操作を1つの `ToolbarItemGroup` や1つの `ControlGroup` にまとめない
- SwiftUI / macOS がカスタマイズ結果を管理する。`NovelDocument`、`.novelpkg`、`AppState` にツールバー順序を保存しない

Scene には `ToolbarCommands()` を追加し、メニューの「ツールバーをカスタマイズ…」と Control-click の標準導線を有効にする。SwiftUI に公開された任意の reset API はないため、独自の「初期配置に戻す」は v1 の非目標とする。

## 5. ツールバーを唯一の入口にしない

macOS ではツールバー自体を非表示にでき、項目も削除できる。すべての操作にメニューバーまたは既存の文脈メニューから到達できるようにする。

| 操作 | ツールバー外の入口 |
| --- | --- |
| Sidebar 表示／非表示 | 表示メニュー / `SidebarCommands()` |
| 章を追加 | 章メニュー + キーボードショートカット |
| 章メモ | 章メニュー / Outline 行の文脈メニュー |
| スナップショットを保存 | File メニューの既存コマンド |
| この章 | Outline 行の文脈メニュー |
| 章内検索 | 編集 > 検索 / Cmd+F |
| AI Assistant | 表示メニュー / Cmd+J |

ツールバーから項目を削除しても機能そのものは無効にならない。

## 6. 検索

### 章内検索

- 右端に `章内を検索` の prompt を持つ、幅広い標準検索欄を常設する
- 既定幅は 320pt を目安とし、最小 240pt、余裕がある場合は 440pt 程度まで広げる
- Cmd+F で検索欄へフォーカスする
- Return で次を検索、Cmd+G で次、Shift+Cmd+G で前を検索する
- Esc はまず検索フォーカスを外す。空欄時は本文へフォーカスを戻す
- 検索対象は現在選択中の章本文。章切り替え時は結果カーソルをリセットする
- 該当なしは検索欄に隣接する一時表示またはアクセシビリティ通知で伝え、上部を2段に増やさない

### Outline 検索との競合回避

現在は Outline と Editor の両方が Cmd+F を持つ。実装時は focused scene value / focused command を使い、次の優先順位へ統一する。

1. Outline にフォーカスがある場合: Outline 絞り込み
2. Editor またはその他にフォーカスがある場合: 章内検索

Outline の上方向スクロールによる検索表示は維持できるが、章内検索欄とは別状態・別 query とする。

## 7. 幅が狭い場合

- toolbar の高さはシステムに任せ、独自の固定高さを設定しない
- Editor の最小可読幅を最優先する
- 幅不足時は、低頻度の編集操作を macOS 標準の overflow へ送る。独自の `…` overflow は作らない
- 検索欄は最小幅まで縮み、その後も Sidebar 切替と検索を優先する
- Outline は STYLE.md の最小 224pt まで縮める
- さらに狭い場合は Project Sidebar を閉じ、Outline + Editor の2列を維持する
- 作品名は省略しても章数は読めるようにする

## 8. View と状態の境界

目標の View 階層は次のとおり。

```text
WindowGroup
└── ContentView
    └── NovelWorkbenchView
        ├── NavigationSplitView
        │   ├── ProjectSidebarView
        │   ├── OutlineContainerView
        │   └── EditorPaneView / Section Detail
        └── WorkbenchToolbarContent
            ├── fixed navigation / identity
            ├── customizable editor commands
            └── editor search
```

- 二重の `HSplitView` を3列の `NavigationSplitView` へ寄せ、標準 Sidebar toggle と列に追従する上部 chrome を得る
- toolbar の所有者は `NovelWorkbenchView` の一箇所だけにする。各ペインから `.toolbar` を追加してマージさせない
- `WorkbenchToolbarContent` は NovelApp 内に置き、AppState の既存操作へ接続する。EditorKit を toolbar 都合で変更しない
- 現在 `EditorPaneView` が持つ query、検索位置、該当なし状態、`EditorSelectionRequest` を、ウィンドウ単位の `EditorSearchSession` へ抽出する
- `EditorSearchSession` は表示用の一時状態であり、`NovelDocument` や保存形式へ追加しない
- 章メモ popover と「この章」メニューは小さい独立 View とし、toolbar content を肥大化させない
- 選択中章がない場合、章依存操作は表示したまま disabled にする。条件分岐で stable ID を消したり作り直したりしない

`NavigationSplitView` 化は toolbar の見た目だけでなく、人物・プロット・単一 detail セクションの列方針にも影響する。実装前に各 `ProjectSection` の content/detail 対応を固定し、`NavigationSplitView` を入れ子にしない。

| ProjectSection | Content / Outline 列 | Detail 列 |
| --- | --- | --- |
| 執筆 | 章・将来のシーン | 本文 Editor |
| 登場人物 | 人物一覧 | 人物シート |
| プロット | カード／伏線のナビゲータ | ボードまたは選択項目の詳細 |
| 資料 | 添付一覧 | 選択資料の情報／Preview |
| 作品情報・企画・世界観・設定 | `概要` またはセクション内項目 | 現在の section surface |

永続モデルがまだないセクションは、既存 placeholder を `概要` detail として再利用する。Toolbar-1 で新しい保存モデルや機能を追加しない。

## 9. 非目標

- ツールバー順序を作品ごとに保存する
- 任意座標へのドラッグ配置
- Sidebar toggle、Outline identity、検索欄の削除
- 独自 toolbar カスタマイズ画面
- AppKit の `NSToolbar` / `NSTrackingSeparatorToolbarItem` を直接操作するブリッジ
- macOS 26 以降だけで使える `ToolbarSpacer` 等への最低対応引き上げ
- プレビュー、スナップショット復元、AI通信など、入口の先にある未実装機能の同時実装

## 10. 実装順

実装は次の2サブフェーズに分け、**1サブフェーズ = 1ブランチ = 1PR**、スタックPR禁止とする。Toolbar-1 / Toolbar-2 は完了。

### Toolbar-1: 3列ワークベンチ基盤【完了】

- [x] root を3列 `NavigationSplitView` へ移行する
- [x] Project Sidebar の標準開閉と、Outline の作品名 + 章数を成立させる
- [x] 各 `ProjectSection` の content/detail 方針を整理し、既存の人物・プロット View の split view 入れ子を解消する
- [x] 既存の `EditorTopBarView` はこの段階では残し、機能導線を失わない

**完了条件:** 全セクションへ到達でき、列幅・Sidebar 開閉・章選択・本文編集が維持される。狭いウィンドウでも Editor の最小幅を守る。

**実装メモ**: `NovelWorkbenchView` を `NavigationSplitView` + 下部 AI Panel に再構成。執筆は Outline / Editor、登場人物は一覧 / シート、プロットは伏線ナビゲータ / ボード、資料は一覧 / 詳細、その他は概要 / section surface。`SidebarCommands()` を追加。人物・プロットの入れ子 split を撤去。

### Toolbar-2: 一段ツールバー + カスタマイズ【完了】

- [x] `WorkbenchToolbarContent` と stable ID を追加する
- [x] 章追加、メモ、スナップショット、この章、検索を native toolbar へ移す
- [x] `EditorTopBarView` と展開式の2段目検索を撤去する
- [x] `ToolbarCommands()` と全操作のメニューバー fallback を追加する
- [x] カスタマイズ配置の再起動保持、overflow、Cmd+F のフォーカス分岐を確認する

**完了条件:** 初期配置が本書の図と一致し、編集操作を個別に移動・削除・再追加できる。toolbar を非表示にしても全機能へ到達できる。

**実装メモ**: `EditorSearchSession` をウィンドウ単位で抽出し、`.searchable(placement: .toolbar)` で右端検索。章メニュー / File のスナップショット復元 / Outline 文脈メニューを fallback に。`ToolbarCommands()` でカスタマイズ導線を有効化。

Toolbar-1 を main にマージしてから Toolbar-2 のブランチを切る、という順序は守った。

## 11. 手動確認

- Project Sidebar toggle が Sidebar の上にあり、表示／非表示／再表示できる
- Outline 上に作品名と正しい章数が表示され、追加・削除で即更新される
- Editor 上部が一段だけで、検索欄が右端に十分な幅で表示される
- 章追加、章メモ、スナップショット、「この章」が既存どおり動く
- ツールバーのカスタマイズ画面で、各編集操作を独立して移動・削除・再追加できる
- カスタマイズ後にアプリを再起動して配置が維持される
- toolbar を非表示にしてもメニューとショートカットから全操作へ到達できる
- Outline / Editor の Cmd+F がフォーカスに応じて正しく分岐する
- ウィンドウを狭めた時にシステム overflow が働き、本文が不必要に潰れない
- ダーク外観でセマンティック素材、標準 focus ring、VoiceOver ラベルが壊れていない
- 日本語IME、自動字下げ、Undo、章切り替え時だけの本文反映(D-005)に回帰がない

## 参考

- [Apple: Toolbars — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/toolbars)
- [Apple: `toolbar(id:content:)`](https://developer.apple.com/documentation/swiftui/view/toolbar%28id%3Acontent%3A%29)
- [Apple: `ToolbarCustomizationBehavior`](https://developer.apple.com/documentation/swiftui/toolbarcustomizationbehavior)
- [Apple: `defaultCustomization(_:options:)`](https://developer.apple.com/documentation/swiftui/customizabletoolbarcontent/defaultcustomization%28_%3Aoptions%3A%29)
- [Apple: Adding a search interface](https://developer.apple.com/documentation/swiftui/adding-a-search-interface-to-your-app)
- [Apple: WWDC22 Compose custom layouts with SwiftUI](https://developer.apple.com/videos/play/wwdc2022/110343/)
