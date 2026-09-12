# macOS Workbenchツールバー

**現行ソース確認: 2026-09-12**

一段のnative toolbarから現在の作品操作へ到達でき、本文の面積と標準のカスタマイズを保つ。見た目は [STYLE.md](STYLE.md)、保存・同期の意味は [Snapshot Sync v2](SNAPSHOT_SYNC_V2.md) に従う。

## 1. 現在の所有者と状態

[`NovelWorkbenchView`](../NovelApp/Features/Writing/NovelWorkbenchView.swift)が`.toolbar(id: "novelwriter.workbench.v7")`を所有し、[`WorkbenchToolbarContent`](../NovelApp/Features/Writing/WorkbenchToolbarContent.swift)が項目を作る。複数paneから独立toolbarを足さない。`EditorSearchSession`やpopoverの表示はwindow内の一時状態とし、作品へ保存しない。

`AppState+SnapshotSyncV2`、`ExplicitSyncButton`、`WorkbenchSyncStatus`へ接続している。旧CloudKitの`workbench.cloud.publish`／`workbench.cloud.sync`は現行項目ではない。ファイルに残る旧Viewや昔の受入記録を現行targetと混同しない。

## 2. 既定レイアウト

- Sidebar上: 標準開閉と作品一覧windowを開く入口。
- Outline上: 作品名・章数などのidentityと、そのsection固有の章／人物／ノート／資料追加。
- Editor上: 左に話追加、保存・同期状態、同期、話メモ、履歴、書き出し、プロットカード参照。右端に標準の話内検索。
- 同期操作と状態を一つのボタンへまとめ、「同期中」「同期済み」「通信待ち」「同期失敗」等を文字で示す。端末内作品や未確認の状態を同期済みと表示しない。
- 保存・同期状態を下部へ重複させず、選択章名はOutlineで示す。

幅不足は標準overflowと列幅調整で扱い、独自の二段目toolbarやoverflowを作らない。同期前の確認表示は`NovelWorkbenchView`側で所有し、overflow内のボタンを表示元にしない。

## 3. 現行項目とstable ID

| ID | 操作 | 配置・カスタマイズ |
| --- | --- | --- |
| `workbench.library` | 作品一覧windowを開く | navigation固定 |
| `workbench.episode.add` | 選択章へ話を追加 | 執筆時、navigation固定 |
| `workbench.snapshot.sync` | 状態を文字表示し、クリックで保存・同期。競合時は確認画面 | 全section、primaryAction固定。macOS 26.1以降は表示優先度high |
| `workbench.writing.assistant` | AI支援inspector開閉 | 執筆時、移動・削除可 |
| `workbench.chapter.memo` | 話メモpopover | 移動・削除可 |
| `workbench.snapshot.save` | スナップショット保存・履歴 | 移動・削除可 |
| `workbench.export` | 書き出す… | 移動・削除可 |
| `workbench.plot.card.rail` | 選択章のプロットカード参照pane | 移動・削除可 |
| `workbench.chapter.add` | 章追加 | 執筆／プロット時、navigation固定 |
| `workbench.character.add` | 人物追加 | 人物section、固定 |
| `workbench.world.note.add` | 世界観ノート追加 | 世界観section、固定 |
| `workbench.plot.card.add` | プロットカード追加 | プロットsection、移動・削除可 |
| `workbench.attachment.add` | 資料取込 | 資料section、固定 |

system sidebar toggleと`.searchable`は標準項目。IDへ作品名・entity ID・配列位置を埋め込まず、単なる改名で変更しない。D-089のAI支援toggleは`workbench.writing.assistant`とCmd+Jを使用する。

## 4. カスタマイズ方針

個別`ToolbarItem(id:)`で独立した移動／削除を許し、複数操作を一つのgroupへまとめない。OSの`ToolbarCommands()`と標準context menuを使用し、順序を`NovelDocument`、package、同期データへ保存しない。

Sidebar・identity・section追加は構造を保つ固定項目。選択不足は必要な操作をdisabledにし、stable IDを作り直さない。未実装機能はdisabled placeholderで出さない。

## 5. ツールバー外の入口

toolbar非表示・項目削除後も、章・人物・世界観・プロット・資料の各menu、Fileの保存／履歴／書き出し、話行context menu、編集menuの検索から同じ操作へ到達できること。追加する操作は既存のcommand境界へ接続し、同じ機能の保存やsession検査を二重実装しない。

## 6. 検索

話内検索は現在の話本文だけが対象。標準toolbar検索欄を使い、Cmd+Fでfocus、Return／Cmd+Gで次、Shift+Cmd+Gで前へ進む。話切替で結果カーソルをresetする。Outlineにfocusがある場合はCmd+FをOutline絞り込みへ送り、queryを共有しない。

幅は既存の320pt目安（最小240pt、余裕時440pt）。該当なしは一時表示やaccessibility通知で示し、toolbarを二段にしない。

## 7. 操作の安全境界

- ⌘Sは「保存して同期」。入力確定→local checkpoint→明示同期要求と進み、変更がない場合もremote確認を要求する。端末内だけの作品は保存に留め、アカウント追加やログインを自動で始めない。認証操作中でもlocal保存は維持する。
- 同期結果はapplicationの状態変更通知をWorkbenchが購読して反映する。購読は作品session／account切替やwindow終了時に取り直し／解除し、overflow内ボタンへ所有させない。remote workerをUI待機にしない。
- 競合確認・履歴・メモの対象は表示時のWorkID／sessionを固定する。操作中の作品切替後に対象を読み替えない。
- remote内容をtoolbar callbackからEditorへ直接書かない。IME、本文所有権、世代検査を既存application境界へ委ねる。
- package内snapshotやFinder表示へfallbackしない。履歴・restoreはv2で扱い、restore前に現在版を保全する。
- exportはcommitted内容から生成し、active WorkIDや保存の正本を変更しない。

## 8. 変更時の完了条件

変更した項目について、既定配置、削除・再配置・再起動、狭幅overflow、menu代替、keyboard／VoiceOverを確認する。検索変更ではfocus分岐、選択／話切替を、保存・履歴変更ではsessionと失敗時保全を確認する。本文操作を変えた場合はIMEとUndoの回帰も確認する。

過去のToolbar-1／2やUI-POL完了を、現在のv2実機・公開Gate完了へ読み替えない。判断が必要なのは製品上の階層や操作の意味を変える場合であり、既存規約内の修正ごとに確認を要求しない。

## 9. 履歴

[旧レイアウト計画・実装順・手動確認項目の全文](archive/product-guidance-20260912/TOOLBAR.md)。旧仕様のCloudKitラベルとpackage snapshotは現行実装の指示ではない。
