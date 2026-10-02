# macOS Workbenchツールバー

一段のnative toolbarから現在の作品操作へ到達でき、本文の面積と標準のカスタマイズを保つ。見た目は [STYLE.md](STYLE.md)、保存・同期の意味は [Snapshot Sync v2](SNAPSHOT_SYNC_V2.md) に従う。

## 1. 現在の所有者と状態

[`NovelWorkbenchView`](../NovelApp/Features/Writing/NovelWorkbenchView.swift)のdetailが`.toolbar(id: "novelwriter.workbench.v8")`を所有し、[`WorkbenchToolbarContent`](../NovelApp/Features/Writing/WorkbenchToolbarContent.swift)が項目を作る。Outlineの章追加・話追加・話名変更などは同ファイルの`WorkbenchOutlineToolbarContent`からcontent列へ提供する。各列のscopeを保つことでOSがSidebar／Outline両方のtracking separatorを作る。独立した二本目のtoolbarや保存・同期処理を作らない。`EditorSearchSession`やpopoverの表示はwindow内の一時状態とし、作品へ保存しない。

`AppState+SnapshotSyncV2`、`ExplicitSyncButton`、`WorkbenchSyncStatus`へ接続している。

## 2. 既定レイアウト

- Sidebar上: 標準開閉。作品一覧へ戻る入口は移動可能な通常項目としてdetail側へ置く。IME確定・端末保存に成功してから同じwindowで一覧へ戻る。
- Outline上: そのsection固有の章／人物／ノート／資料追加。作品名はOutline上に置かず、本文領域上端の見出しとして表示する。
- 執筆のOutline上: 章追加、話追加、話名変更の順。Editor上: 作品一覧、可変余白、話メモ、履歴、保存して同期、書き出し、プロットカード、話内検索、右端にAI支援。
- 同期操作と状態を一つのボタンへまとめ、「同期中」「同期済み」「通信待ち」「同期失敗」等を文字で示す。端末内作品や未確認の状態を同期済みと表示しない。
- 保存・同期状態を下部へ重複させず、選択章名はOutlineで示す。

幅不足は標準overflowと列幅調整で扱い、独自の二段目toolbarやoverflowを作らない。同期前の確認表示は`NovelWorkbenchView`側で所有し、overflow内のボタンを表示元にしない。

作品一覧とWorkbenchは標準unified toolbar styleを使う。SidebarとOutlineの区切りはnativeの追従に任せ、項目に必要な幅を下回ると独立した区切りになり、余裕が戻ると再び列境界へ追従する。本文背景のドラッグ判定は変更しない。

## 3. 現行項目とstable ID

| ID | 操作 | 配置・カスタマイズ |
| --- | --- | --- |
| `workbench.library` | 保存して同じwindowの作品一覧へ戻る | 移動・削除可 |
| `workbench.episode.add` | 選択章へ話を追加 | 執筆時、移動・削除可 |
| `workbench.snapshot.sync` | 状態を文字表示し、クリックで保存・同期。競合時は確認画面 | 全section、移動・削除可。macOS 26.1以降は表示優先度high |
| `workbench.episode.rename` | 選択中の話の名前を変更 | 執筆時、移動・削除可 |
| `workbench.writing.assistant` | AI支援右パネル開閉 | 執筆時、移動・削除可 |
| `workbench.chapter.memo` | 話メモpopover | 移動・削除可 |
| `workbench.snapshot.save` | スナップショット保存・履歴 | 移動・削除可 |
| `workbench.export` | 書き出す… | 移動・削除可 |
| `workbench.plot.card.rail` | 選択章のプロットカード参照pane | 移動・削除可 |
| `workbench.chapter.add` | 章追加 | 執筆／プロット時、移動・削除可 |
| `workbench.character.add` | 人物追加 | 人物section、移動・削除可 |
| `workbench.world.note.add` | 世界観ノート追加 | 世界観section、移動・削除可 |
| `workbench.plot.card.add` | プロットカード追加 | プロットsection、移動・削除可 |
| `workbench.attachment.add` | 資料取込 | 資料section、移動・削除可 |

話内検索は`workbench.search`の通常項目内にnative NSSearchFieldを置き、移動・削除できる。system sidebar toggleは標準項目。IDへ作品名・entity ID・配列位置を埋め込まず、単なる改名で変更しない。D-089のAI支援toggleは`workbench.writing.assistant`とCmd+Jを使用する。

## 4. カスタマイズ方針

個別`ToolbarItem(id:)`で独立した移動／削除を許し、複数操作を一つのgroupへまとめない。OSの`ToolbarCommands()`と標準context menuを使用し、順序を`NovelDocument`、package、同期データへ保存しない。

アプリ固有の操作は全て通常項目として移動・削除を許す。Sidebar開閉、列区切りなどOSが管理する構造は標準の制約に従う。選択不足は必要な操作をdisabledにし、stable IDを作り直さない。未実装機能はdisabled placeholderで出さない。

## 5. ツールバー外の入口

toolbar非表示・項目削除後も、章・人物・世界観・プロット・資料の各menu、Fileの保存／履歴／書き出し、話行context menu、編集menuの検索から同じ操作へ到達できること。追加する操作は既存のcommand境界へ接続し、同じ機能の保存やsession検査を二重実装しない。

## 6. 検索

話内検索は現在の話本文だけが対象。標準toolbar検索欄を使い、Cmd+Fでfocus、Return／Cmd+Gで次、Shift+Cmd+Gで前へ進む。話切替で結果カーソルをresetする。Outlineにfocusがある場合はCmd+FをOutline絞り込みへ送り、queryを共有しない。

検索欄は最小160pt、目安260pt、最大320pt。該当なしは一時表示やaccessibility通知で示し、toolbarを二段にしない。

## 7. 操作の安全境界

- ⌘Sは「保存して同期」。入力確定→local checkpoint→明示同期要求と進み、変更がない場合もremote確認を要求する。端末内だけの作品は保存に留め、アカウント追加やログインを自動で始めない。認証操作中でもlocal保存は維持する。
- 同期結果はapplicationの状態変更通知をWorkbenchが購読して反映する。購読は作品session／account切替やwindow終了時に取り直し／解除し、overflow内ボタンへ所有させない。remote workerをUI待機にしない。
- 競合確認・履歴・メモの対象は表示時のWorkID／sessionを固定する。操作中の作品切替後に対象を読み替えない。
- remote内容をtoolbar callbackからEditorへ直接書かない。IME、本文所有権、世代検査を既存application境界へ委ねる。
- package内snapshotやFinder表示へfallbackしない。履歴・restoreはv2で扱い、restore前に現在版を保全する。
- exportはcommitted内容から生成し、active WorkIDや保存の正本を変更しない。

## 8. 変更時の完了条件

変更した項目について、既定配置、削除・再配置・再起動、狭幅overflow、menu代替、keyboard／VoiceOverを確認する。検索変更ではfocus分岐、選択／話切替を、保存・履歴変更ではsessionと失敗時保全を確認する。本文操作を変えた場合はIMEとUndoの回帰も確認する。

## 9. 作品一覧・名前変更・プロット参照

macOSは`workbench`の単一Window sceneを使う。未選択時は全幅の作品一覧、open・新規・Import成功後は同じwindowのWorkbenchを表示する。失敗時は現在の画面と原稿を保つ。独立したlibrary windowは設けない。「作品一覧…」はtoolbarと同じ入力確定・保存境界を通る。

端末内作品の保存は同じWorkIDへの保存だけ。同期用コピーは右クリックの「同期用のコピーを作成…」で明示し、通常保存やCmd+Sで作品数を増やさない。

執筆画面下部は横並びのプロットカードだけを表示し、専用見出し・区切り・閉じるボタンは置かない。開閉は既存toolbarから行う。プロット編集画面の右detailは上段カード／下段伏線とし、執筆下部に伏線を置かない。

話名はtoolbarと話行のcontext menuから変更でき、既存の一覧内編集も維持する。dialogはpane側で所有し、overflowへ閉じ込めない。作品名は一覧のcontext menuから変更する。両者とも空白だけの名前を拒否し、取得元session/accountと対象の存在を確認してmetadataをSQLiteへ保存する。本文・選択・Editor世代を変えない。remote-only作品名変更は必要な取得後に行い、networkをdocument gate内で待たない。

native toolbarの配置は端末UserDefaultsへsection別に保持し、window再構築後に復元する。検索を削除した場合は本文側Cmd+Fで再追加してfocusする。検索先は実際にfocusがあるViewの`focusedValue`で決め、複数列の`focusedSceneValue`で競合させない。配置・検索語は作品へ同期しない。

## AI支援の幅

右側のAI支援パネルは左端の境界を左右へドラッグして幅を変更できる。既定360pt、最小300pt、最大720ptかつウインドウ幅の45%を目安に制限し、本文側の表示領域を残す。幅は端末設定に保存し、パネルを閉じて開き直した場合やアプリ再起動後も引き継ぐ。VoiceOverの調整操作にも対応する。

## サムネイルの入口

作品情報・人物詳細・世界観ノート詳細の画像menuから設定／置換／削除する。画像のcontext menuも同じ操作を提供し、画像wellへのファイルdrag & dropは同じ切り抜きsheetへ進む。toolbar項目は追加しない。棚では表紙と既存の同期記号・文言を併存させる。[保存契約](sync/v2/thumbnails.md)。

作品一覧のヘッダーにアプリ名・新規・Importを置く。表紙／一覧切替、⌘F検索、表紙の矢印キー選択、Return／double clickでopenに対応する。⌘⇧Lは同じwindowで一覧へ戻る。閉じたwindowは標準Windowメニューから再表示する。
