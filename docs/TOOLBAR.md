# macOS Workbenchツールバー

**現行ソース確認: 2026-09-13**

一段のnative toolbarから現在の作品操作へ到達でき、本文の面積と標準のカスタマイズを保つ。見た目は [STYLE.md](STYLE.md)、保存・同期の意味は [Snapshot Sync v2](SNAPSHOT_SYNC_V2.md) に従う。

## 1. 現在の所有者と状態

[`NovelWorkbenchView`](../NovelApp/Features/Writing/NovelWorkbenchView.swift)のdetailが`.toolbar(id: "novelwriter.workbench.v8")`を所有し、[`WorkbenchToolbarContent`](../NovelApp/Features/Writing/WorkbenchToolbarContent.swift)が項目を作る。Outlineの章追加・話追加・話名変更などは同ファイルの`WorkbenchOutlineToolbarContent`からcontent列へ提供する。各列のscopeを保つことでOSがSidebar／Outline両方のtracking separatorを作る。独立した二本目のtoolbarや保存・同期処理を作らない。`EditorSearchSession`やpopoverの表示はwindow内の一時状態とし、作品へ保存しない。

`AppState+SnapshotSyncV2`、`ExplicitSyncButton`、`WorkbenchSyncStatus`へ接続している。旧CloudKitの`workbench.cloud.publish`／`workbench.cloud.sync`は現行項目ではない。ファイルに残る旧Viewや昔の受入記録を現行targetと混同しない。

## 2. 既定レイアウト

- Sidebar上: 標準開閉。作品一覧へ戻る入口は移動可能な通常項目としてdetail側へ置く。IME確定・端末保存に成功してから一覧を開き、編集windowを閉じる。
- Outline上: そのsection固有の章／人物／ノート／資料追加。作品名はOutline上に置かず、本文領域上端の見出しとして表示する。
- 執筆のOutline上: 章追加、話追加、話名変更の順。Editor上: 作品一覧、可変余白、話メモ、履歴、保存して同期、書き出し、プロットカード、話内検索、右端にAI支援。2026-09-13の利用者提示画像を既定配置にする。
- 同期操作と状態を一つのボタンへまとめ、「同期中」「同期済み」「通信待ち」「同期失敗」等を文字で示す。端末内作品や未確認の状態を同期済みと表示しない。
- 保存・同期状態を下部へ重複させず、選択章名はOutlineで示す。

幅不足は標準overflowと列幅調整で扱い、独自の二段目toolbarやoverflowを作らない。同期前の確認表示は`NovelWorkbenchView`側で所有し、overflow内のボタンを表示元にしない。

作品一覧とWorkbenchは標準unified toolbar styleを使う。SidebarとOutlineの区切りはnativeの追従に任せ、項目に必要な幅を下回ると独立した区切りになり、余裕が戻ると再び列境界へ追従する。本文背景のドラッグ判定は変更しない。

## 3. 現行項目とstable ID

| ID | 操作 | 配置・カスタマイズ |
| --- | --- | --- |
| `workbench.library` | 保存して作品一覧へ戻り、編集windowを閉じる | 移動・削除可 |
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

過去のToolbar-1／2やUI-POL完了を、現在のv2実機・公開Gate完了へ読み替えない。判断が必要なのは製品上の階層や操作の意味を変える場合であり、既存規約内の修正ごとに確認を要求しない。

## 9. 履歴

[旧レイアウト計画・実装順・手動確認項目の全文](archive/product-guidance-20260912/TOOLBAR.md)。旧仕様のCloudKitラベルとpackage snapshotは現行実装の指示ではない。

作品一覧を先頭の起動sceneとする。一覧で作品を開けた場合、新規作成・取り込みが成功した場合は編集windowを開いて一覧windowを閉じる。失敗した場合は現在のwindowを維持する。メニューの「作品一覧…」もtoolbarと同じ保存境界を通る。

2026-09-12追加依頼: macOSのAI支援は右、プロットカードは本文下部へ配置する。プロットカードtoggleは `rectangle.bottomthird.inset.filled` を使用する。

ローカル作品の保存ボタンは同じWorkIDのローカル保存だけを行う。同期用の複製はボタンの右クリックメニュー「同期用のコピーを作成…」で明示する。通常保存・Cmd+Sでは作品数を増やさない。プロット編集画面の右側detail列は上下分割し、上段にプロットカード、下段に伏線を配置する。執筆画面下部はプロットカード専用とし、伏線は表示しない（最新の配置訂正）。

2026-09-12 話名変更: 執筆ツールバーの「話の名前を変更」と話一覧の右クリックから、名前変更ダイアログを開く。既存の一覧内直接編集も維持する。ダイアログはpane側で所有し、toolbar overflow内へ閉じ込めない。確定時に取得元の作品session・account scope・章内の話の存在を検証し、本文、選択中の話、Editorの内容世代を変えずmetadataを通常保存する。空白だけの名前は確定できない。

2026-09-12 作品一覧の名前変更: 作品行の右クリック「作品名を変更…」で作品名を編集する。一覧の表示名だけを変更するのではなく、同じWorkIDの作品metadataをSQLiteへcheckpointする。本文・資料・履歴を保持し、編集中の作品や話を切り替えない。端末内の作品は通信待ちなし、サーバーのみの作品は明示的な取得後に変更する。確認元session/accountを検証し、取得中はdocument gateを占有しない。

### 2026-09-12 メモアプリの参考動画に合わせた確認

中ぐらいの検証。macOSの表示・プロット選択11テスト成功。native toolbarにSidebarとOutlineの2本のtracking separatorがあること、中央列の縮小・復帰とAI開閉で同じ本文viewを保つこと、アプリ操作がnativeのカスタマイズ候補でありnavigation固定でないことを確認した。

参考: [Appleのtoolbarとsplit-viewの説明](https://developer.apple.com/videos/play/wwdc2020/10104/)。

更新版macOSで中央列を224ptから約440ptへ広げ、操作列が境界に追従し、作品名が本文上端に留まることを確認。標準カスタマイズ画面で各操作を確認した。同期項目のpalette名を「保存して同期」とし、表示5テストを再実行して成功。macOS通常版build成功。iOS変更・実API送信は対象外。

2026-09-13: 執筆画面下部は見出し行・区切り線・専用の閉じるボタンをなくし、横並びのプロットカード一覧だけにする。開閉は既存のツールバーボタンから行う。プロット編集画面のカード／伏線の上下分割は維持する。

同変更は軽い検証を実施。macOS build成功。更新版の執筆画面で、下部にカード一覧のみが表示され、欄内の見出し・区切り・閉じるボタンがなく、開閉ボタンが表示中になることを確認した。

2026-09-13: toolbar IDをv8へ一度更新して依頼された既定順へ切り替える。以後のnativeカスタマイズは端末内UserDefaultsにsection別で保持し、SwiftUIのwindow再構築後に復元する。split viewのtracking separatorはOSの管理を維持する。検索を削除した場合は本文側のCmd+Fで再追加してfocusする。検索語や配置は作品へ同期しない。

本文とOutlineの検索先は、scene全体の値ではなく実際にfocusがあるViewの`focusedValue`から決める。Scene内のfocus位置に依存しない`focusedSceneValue`を両方の列へ置くと検索先が競合するため使用しない（[Appleの区別](https://developer.apple.com/documentation/swiftui/view/focusedscenevalue%28_%3A_%3A%29)）。Mac実画面で本文→話内検索、Outline→一覧検索のCmd+F分岐を確認した。
