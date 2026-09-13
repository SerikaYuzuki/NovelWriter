# ふみにわのデザイン言語

**適用: UIを変更する作業 / ソースとの照合: 2026-09-12**

本文を主役にした「静かな書斎」を保つ。macOSはSwiftUI + AppKit、iOS / iPadOSはSwiftUI + UIKitの標準操作、semantic color、system materialを優先する。本書は製品要件であり、全画面が達成済みという宣言ではない。現行iOSの不足は [IOS.md](IOS.md)、同期状態の意味は [Snapshot Sync v2](SNAPSHOT_SYNC_V2.md) を参照する。

## 1. 外観と情報階層

- chromeはmacOSでSystem既定、iOSで初回Dark既定。System／Light／Darkの明示選択を保持する(D-044／D-057)。
- 本文キャンバスの色・フォントはchromeと独立した端末設定。OS外観変更で上書きせず、作品へ保存しない。
- 本文を最も広くし、Sidebar／Outline／toolbarは控えめにする。未実装機能やAIの予約領域を表示しない。
- 棚は単一の作品一覧。通常操作に内部path、DB、WorkIDを出さず、外部packageは「作品を取り込む…」「書き出す…」から扱う。
- macOSは作品一覧からWorkbench、iOSは作品棚から作品ホームと各機能へ進む。製品上の階層は維持し、旧CloudKitのラベルや保存処理は戻さない。

## 2. カラー

まず`primary`／`secondary`、OSのbackground／separator等を使う。固定色は以下のtokenと本文の利用者設定に限定する。彩度はドットや小さなアクセントへ使い、大きな面や画面全体をブランド色で塗らない。

| token | Dark基準値 | 用途 |
| --- | --- | --- |
| canvas | `#171719` | 本文と最背面 |
| surface | `#202126` | 面の参考値。chromeはsystem material優先 |
| surfaceRaised | `#292A30` | 一段上の面 |
| border | `#3A3B42` | 基本はsemantic separator |
| accent | `#8CA7DF` | 選択・リンク。iOS Light側は既存paletteの`#34558B` |
| warning | `#E8A54A` | 注意 |
| success | `#7FBF8A` | 完了 |
| danger | `#E07A7A` | 破壊的操作の補助。button roleを併用 |

人物識別の既定10色は`#C25450`、`#C97F3D`、`#B89A3A`、`#5B9160`、`#4E9091`、`#5077B0`、`#6A6FB2`、`#8E6AA8`、`#B0628C`、`#8A7A6A`。基本は8ptの識別ドットで、任意色は利用者設定として扱う。

## 3. タイポグラフィ

| 対象 | 規約 |
| --- | --- |
| UI見出し | system `.headline` |
| フォーム・本文UI | `.body` |
| サブ情報・status | `.caption` + `.secondary` |
| 文字数・数値 | `.monospacedDigit()` |
| Editor本文 | 既定ヒラギノ明朝ProN 16pt、行間1.5、文字`#E8E6DF`、背景`#171719` |

UIへ任意のフォントサイズを直書きしない。本文は利用者がフォント・サイズ・行間・配色を設定できる境界とし、OS側で提供している設定範囲は各platformの実装へ照合する。補助入力の話メモ等はsystem fontを使う。

本文insetは左右・上下16pt、末尾に96ptの表示余白を置く。改行や空白を本文へ追加して余白を作らない。macOS本文幅は無制限が既定で、700pt／900ptへ変更できる。

## 4. スペーシングとレイアウト

- 8ptグリッドを基本とし4pt刻みを許す。既定の外周20pt、グループ間16pt、グループ内8ptを使い、場当たりの数値を増やさない。
- 角丸はカード／パネル8pt、チップ4pt。枠はseparatorのhairline。常設の影を付けない。
- macOSの基準はSidebar 200pt（184〜224）、Outline 360pt（224〜440）、status bar 28pt。プロットlane 260pt、人物一覧280pt（最小240）。
- Outlineがある機能はSidebar／Outline／Detail。作品情報・設定はSidebar／Detail。splitを入れ子にしない。
- 狭幅では低頻度操作の標準overflowとOutline縮小を使い、本文の可読幅を守る。toolbarは一段で高さ・paddingをOSへ任せる。
- Sidebar／Outline／detail chromeは`.thinMaterial`。既存の`workbenchGlassChromeStyle()`／`workbenchOutlineListStyle()`を使い、materialを二重にしない。本文・世界観Editorだけは不透明キャンバス。
- フォームはsystem grouped styleまたは既存Labeled Field。長文はラベル→8pt→入力、入力inset 8pt。
- iOSの執筆補助バーは本文直下、keyboard表示時はIME直上。本文と同じ不透明背景でsafe areaまで連続させ、各操作を44pt以上にする。

## 5. コンポーネント

- 標準button、List selection、focus ringを使う。主操作は`.borderedProminent`、通常は`.bordered`、toolbar／行内は`.borderless`。破壊的操作は`.destructive`と対象が分かる確認を付ける。
- Sidebarはアイコン＋短い名詞。通常行はタイトル＋captionの2行。章Disclosureは章名・話数・文字数を一行にし、label全体で開閉できるようにする。
- 空状態は`ContentUnavailableView`で状況と次の一歩を示す。未設定、読込失敗、offlineを「作品がありません」にまとめない。
- macOSのtoolbarは [TOOLBAR.md](TOOLBAR.md)。保存／同期は上部へ集約し、下部は話／全体文字数や検索結果などに使う。同じ保存状態を上下に重複させない。
- iOS本文の重複見出し・タイトル入力・文字数・下部status barを常設しない。執筆補助のdisabled理由は見た目とVoiceOverへ伝える。
- プロットカードは淡い面＋separator＋8pt角丸。ドラッグ中だけ控えめな影を許す。

## 6. 起動・同期・復旧の表示

- Loading／作品選択／Recoveryでは編集可能なWorkbenchを出さない。local読込失敗を空の新規作品へ置き換えない。
- 新規／Importと検証済みlocal作品のopenは、accountやnetwork未確認だけを理由に止めない。
- local保存、同期待ち、同期済み、offline、未取得、競合、別account保留を区別する。「同期済み」は検証済みのaccount範囲とheadに基づくprojectionだけに使う。
- unbound作品を「接続後に同期」と表示しない。別account作品はlocal編集を保持し、未取得の別account行／titleは見せない。
- 競合は「この端末の版を使う／サーバーの版を使う／両方を残す」。未選択のwinnerを決めず、通常のremote競合で全画面の編集を止めない。
- 復元前の内容を保全する。Snapshot ID、SQLite、journal、fence、commandの説明を通常の判断材料にしない。
- 変更のない保存／同期は成功。「コピー」「予約」「local保存」「remote反映」「復元」を混同しない。

現行v2の一部画面には診断用ラベルが残る。これは本書の規約変更ではなく、製品UIへ直す差分として扱う。

## 7. インタラクション

- フォーカスと選択はOS標準。アニメーションは既存`.snappy`（目安0.2秒）へ揃え、0.5秒超やバウンスを増やさない。
- 編集一覧はEnterで編集、Deleteは確認付き削除。作品chooserは選択とopenを分け、ListにfocusがあるときのReturnとdouble clickで開く。
- toolbarを唯一の入口にしない。削除可能なitemにはmenu／context menuの代替を残す。
- macOSはCmd+1〜7でsection、Cmd+Nで新規、Cmd+OでImport、Cmd+Shift+SでExport。Cmd+Fはfocus対象のOutline検索／話内検索を使い分ける。
- Cmd+Sは同じlocal保存直列化へ接続する。保存後のv2 workerは非同期で再開し、network完了を待たない。D-073の「明示同期だけ送信」は旧実装の規則。

## 8. 文言

短い名詞または動詞を使う。続く入力／選択には「…」、確認buttonは「削除／キャンセル」等の動詞、説明はです・ます体。省スペースの執筆補助labelは「ルビ」「傍点」でよい。

現行同期はFUMINIWA serverである。「iCloudに保存」「iCloudと同期」を使わない。内部path／IDや未実装の処理を見せず、clipboard支援は「校正用／アドバイス用プロンプトをコピー」と表現する。D-089のAPI支援は「本文を確認して送信…」からpreview後に明示送信し、コピーと区別する。

## 9. 変更の受け入れ

変更した画面に関係する項目を確認し、結果と未確認を記録する。無関係な画面の全検証を毎回繰り返す必要はない。

- System／Light／Dark、Reduce Transparency、文字とseparatorの可読性、本文設定の保持。
- 狭幅と拡大文字、標準keyboard、VoiceOver、44pt操作面、focusとtoolbar代替入口。
- 本文所有権、IME、sessionをまたぐ操作の拒否、編集操作のUndo。
- 状態表示と実処理の一致、失敗時の原稿保持、空状態からの実在する操作。
- 本書のtoken／余白／階層と [iOSの未接続項目](IOS.md) に対する回帰。

色・配置の微調整は既存規約内で進める。外観既定、機能階層、保存／同期の意味を変える場合は製品判断として [DECISIONS.md](DECISIONS.md) を更新する。
