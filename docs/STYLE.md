# ふみにわのデザイン言語

**適用: 画面の外観・操作を変えるとき。**

本文を主役にした「静かな書斎」を保つ。macOSはSwiftUI + AppKit、iOS / iPadOSはSwiftUI + UIKitの標準操作、semantic color、system materialを優先する。本書は製品要件であり、全画面が達成済みという宣言ではない。現行iOSの不足は [IOS.md](IOS.md)、同期状態の意味は [Snapshot Sync v2](SNAPSHOT_SYNC_V2.md) を参照する。

## 1. 外観と情報階層

- chromeはmacOSでSystem既定、iOSで初回Dark既定。System／Light／Darkの明示選択を保持する(D-044／D-057)。
- 本文キャンバスの色・フォントはchromeと独立した端末設定。OS外観変更で上書きせず、作品へ保存しない。
- 本文を最も広くし、Sidebar／Outline／toolbarは控えめにする。未実装機能やAIの予約領域を表示しない。
- 棚は単一の作品一覧。通常操作に内部path、DB、WorkIDを出さず、外部packageは「作品を取り込む…」「書き出す…」から扱う。
- macOSは同じwindow内の全幅作品一覧からWorkbench、iOSは作品棚から作品ホームと各機能へ進む。製品上の階層は維持し、旧CloudKitのラベルや保存処理は戻さない。

## 2. カラー

固定色はNovelUIの`FuminiwaColor` tokenと本文設定に限る。棚・作品ホーム・詳細はpaper／surfaceを面に使ってよい。accent（藍）は選択・主操作・リンク、leaf（若葉）は完了・進み具合に限り、大きな面を高彩度で塗らない。利用者の画像（表紙・人物・世界観）は面積の例外。Sidebar・toolbarはsystem material、本文は利用者設定のまま。

| token | Light | Dark |
| --- | --- | --- |
| paper | `#F8F5EF` | `#18181B` |
| surface | `#FFFDF9` | `#212126` |
| elevatedSurface | `#FFFFFF` | `#2A2A30` |
| sunken | `#F0ECE3` | `#131316` |
| separator | `#E3DDD1` | `#3A3B42` |
| textPrimary | `#23211D` | `#ECE9E2` |
| textSecondary | `#6B655B` | `#A6A29A` |
| textTertiary | `#9A9488` | `#706C66` |
| accent | `#34558B` | `#8CA7DF` |
| accentMuted | `#E4E9F3` | `#263049` |
| leaf | `#50704A` | `#9DB58E` |
| warning | `#9A5A00` | `#E8A54A` |
| danger | `#B3413B` | `#E07A7A` |

本文UIは両外観でWCAG 4.5:1以上をテストする。textTertiaryは補助記号・装飾用とし、本文文字はtextSecondaryを使う。Increase Contrast／Reduce Transparencyは標準部品の挙動を保つ。

人物識別の既定10色は`#C25450`、`#C97F3D`、`#B89A3A`、`#5B9160`、`#4E9091`、`#5077B0`、`#6A6FB2`、`#8E6AA8`、`#B0628C`、`#8A7A6A`。色名は順に紅、柿、芥子、松、青磁、縹、藤紫、菖蒲、梅紫、胡桃。help／VoiceOverは色名を使う。任意色は利用者設定として扱う。

## 3. タイポグラフィ

| 対象 | 規約 |
| --- | --- |
| UI見出し | system `.headline` |
| フォーム・本文UI | `.body` |
| サブ情報・status | `.caption` + `.secondary` |
| 文字数・数値 | `.monospacedDigit()` |
| Editor本文 | 既定ヒラギノ明朝ProN 16pt、行間1.5、文字`#E8E6DF`、背景`#171719` |

作品名（表紙・作品ホーム・作品情報の見出し）に限りヒラギノ明朝W6を`relativeTo:`付きで使う。棚見出しはlargeTitle、詳細見出しはtitle2.semibold、行の補足はiOS subheadline／macOS caption、メタ情報はcaption2。UIへ任意のフォントサイズを直書きしない。本文は利用者がフォント・サイズ・行間・配色を設定できる境界とし、OS側で提供している設定範囲は各platformの実装へ照合する。補助入力の話メモ等はsystem fontを使う。

本文insetは左右・上下16pt、末尾に96ptの表示余白を置く。改行や空白を本文へ追加して余白を作らない。macOS本文幅は無制限が既定で、700pt／900ptへ変更できる。

## 4. スペーシングとレイアウト

- `Spacing`は2／4／8／12／16／20／24／32／48pt。既定の外周20pt、グループ間16pt、グループ内8ptを使い、場当たりの数値を増やさない。
- 角丸は`Radius` token（continuous）：chip 4、thumbnail 6、card 10、hero 14、表紙4pt＋内側hairline。影は表紙サムネイルの1層（黒、Light 0.12／Dark 0.4、radius 3、y 1）とドラッグ中のカードだけ。
- macOSの基準はSidebar 200pt（184〜224）、Outline 360pt（224〜440）、status bar 28pt。プロットlane 260pt、人物一覧280pt（最小240）。
- Outlineがある機能はSidebar／Outline／Detail。作品情報・設定はSidebar／Detail。splitを入れ子にしない。
- 狭幅では低頻度操作の標準overflowとOutline縮小を使い、本文の可読幅を守る。toolbarは一段で高さ・paddingをOSへ任せる。
- Sidebar／Outline／toolbarはsystem material。詳細の面はpaper／surface。既存の`workbenchGlassChromeStyle()`／`workbenchOutlineListStyle()`を使い、materialを二重にしない。本文・世界観Editorだけは不透明キャンバス。
- フォームはsystem grouped styleまたは既存Labeled Field。長文はラベル→8pt→入力、入力inset 8pt。
- iOSの執筆補助バーは本文直下、keyboard表示時はIME直上。本文と同じ不透明背景でsafe areaまで連続させ、各操作を44pt以上にする。

## 5. コンポーネント

- 標準button、List selection、focus ringを使う。主操作は`.borderedProminent`、通常は`.bordered`、行内は`.borderless`。toolbarのlabel style／button style／control sizeはOS標準に任せる。破壊的操作は`.destructive`と対象が分かる確認を付ける。
- Sidebarはアイコン＋短い名詞。通常行はタイトル＋captionの2行。章Disclosureは章名・話数・文字数を一行にし、label全体で開閉できるようにする。
- 空状態は`ContentUnavailableView`で状況と次の一歩を示し、実在する操作ボタンを付ける。未設定、読込失敗、offlineを「作品がありません」にまとめない。
- macOSのtoolbarは [TOOLBAR.md](TOOLBAR.md)。保存／同期は上部へ集約し、下部は話／全体文字数や検索結果などに使う。同じ保存状態を上下に重複させない。
- 進み具合カードは今日の加筆量と純増、週列・曜日行のカレンダー、継続／今週の執筆日数、目標・締切・到達一覧をまとめる。カレンダーは0／1–499／500–1999／2000–4999／5000字以上の固定段階（sunken／accentの不透明度0.25・0.45・0.7・1）。横スクロールせず、macOSは最大26週、iOSは幅に収まる最大16週。VoiceOverは表示期間の日数・合計を要約する。
- macOS執筆補助バー右端はcaption・secondary・monospacedDigitの「話 3,210字 · 今日 +1,240字」。数値は操作群のdisabledから分離し、到達通知時は約5秒置き換える。入力中はアニメーションしない。
- iOS本文の重複見出し・タイトル入力・文字数・下部status barを常設しない。執筆補助のdisabled理由は見た目とVoiceOverへ伝える。
- プロットカードは淡い面＋separator＋Radius.card角丸。ドラッグ中だけ控えめな影を許す。

- サムネイル：表紙は2:3、一覧32×48、grid幅120〜150（iOS 104〜140）、home 96×144。人物は円形、一覧macOS 24／iOS 28、詳細72。世界観は角丸正方形、一覧28、詳細96。
- 画像なしの表紙はpaper＋藍の帯＋作品名の先頭から数字・空白・句読点・記号を除いた最初の1文字（明朝、該当文字がなければ「文」）。人物はcolorHexの円＋頭文字（色なしは中立色）、世界観はaccentMuted＋`globe.asia.australia`。画像は表示寸法でdecode・cacheする。
- 棚はtoolbarの標準Pickerで表紙／一覧を切り替え、端末のAppStorageへ記憶する。表紙はLazyVGrid、一覧は既存の行操作を保つ。iOSのアクセシビリティ文字サイズでは保存した選択を変えず一覧へ戻す。取り込みの進捗・中止・再試行は両形式のカード／行とcontext menuから利用できる。
- 人物詳細は72ptの画像＋名前・ふりがな・役割を見出しにまとめ、設定をsurface cardへ分ける。色の選択状態はringとcheckmarkでも伝える。世界観詳細の画像領域は設定済みのときだけ表示し、未設定でも画像設定・dropの入口を残す。
- プロット・伏線は`surfaceCard`相当の面と0.5ptの境界、選択は1.5ptのaccent。iPadはカード、iPhone・拡大文字・並べ替え編集中は一覧。未回収はwarningの`flag`、回収済みはleafの`checkmark.circle.fill`。通常時は影を付けない。
- 切り抜きは対象形状の外側を暗くし、輪郭を表示する。位置・倍率の操作を保ち、「使用する」を主操作にする。
- 状態は原則として記号＋文字。macOS toolbarの同期状態だけはD-110により記号＋色とし、全文をhelp／accessibility labelに残す。標準の「アイコンとテキスト」表示では状態名も示す。同期済みleaf、同期中／未取得accent、同期待ち／端末内secondary、offlineは記号tertiary・文字secondary、競合warning、失敗danger。文言と意味は共通applicationに従う。SF Symbolsはhierarchical、system weight。

## 6. 起動・同期・復旧の表示

- Loading／作品選択／Recoveryでは編集可能なWorkbenchを出さない。local読込失敗を空の新規作品へ置き換えない。
- 新規／Importと検証済みlocal作品のopenは、accountやnetwork未確認だけを理由に止めない。
- local保存、同期待ち、同期済み、offline、未取得、競合、別account保留を区別する。「同期済み」は検証済みのaccount範囲とheadに基づくprojectionだけに使う。
- unbound作品を「接続後に同期」と表示しない。別account作品はlocal編集を保持し、未取得の別account行／titleは見せない。
- 競合は「この端末の版を使う／サーバーの版を使う」の2択。選ばなかった版は履歴から復元できる。選択中は同じ競合への再選択を無効にする。未選択のwinnerを決めず、通常のremote競合で全画面の編集を止めない。
- 復元前の内容を保全する。Snapshot ID、SQLite、journal、fence、commandの説明を通常の判断材料にしない。
- 変更のない保存／同期は成功。「コピー」「予約」「local保存」「remote反映」「復元」を混同しない。

通常画面に内部ID等の診断表示を追加しない。診断が必要な場合は通常操作と分ける。

## 7. インタラクション

- フォーカスと選択はOS標準。`Motion.standard`（短いease）を使い、Reduce Motion時はnil。本文入力中に数値や記号のアニメーションを動かさない。
- macOS本文の「滑らかなカーソル」は既定ON。設定からOFFにでき、OSの「視差効果を減らす」では標準表示に戻す。縦線だけを90msで追従させ、IME候補の位置や実際の入力位置は遅らせない。
- 編集一覧はEnterで編集、Deleteは確認付き削除。作品chooserは選択とopenを分け、ListにfocusがあるときのReturnとdouble clickで開く。
- toolbarを唯一の入口にしない。削除可能なitemにはmenu／context menuの代替を残す。
- macOSはCmd+1〜7でsection、Cmd+Nで新規、Cmd+OでImport、Cmd+Shift+SでExport。Cmd+Fは作品一覧では棚検索へfocusし、Workbenchではfocus対象のOutline検索／話内検索を使い分ける。
- Cmd+Sは同じlocal保存直列化へ接続する。保存後のv2 workerは非同期で再開し、network完了を待たない。

## 8. 文言

短い名詞または動詞を使う。続く入力／選択には「…」、確認buttonは「削除／キャンセル」等の動詞、説明はです・ます体。省スペースの執筆補助labelは「ルビ」「傍点」でよい。

現行同期はFUMINIWA serverである。「iCloudに保存」「iCloudと同期」を使わない。内部path／IDや未実装の処理を見せず、原稿コピーは「選択範囲をコピー」「この話をコピー」「この章をコピー」と表現する。D-089のAPI支援は「本文を確認して送信…」からpreview後に明示送信し、コピーと区別する。

## 9. 変更の受け入れ

変更した画面に関係する項目を確認し、結果と未確認を記録する。無関係な画面の全検証を毎回繰り返す必要はない。

- System／Light／Dark、Reduce Transparency、文字とseparatorの可読性、本文設定の保持。
- 狭幅と拡大文字、標準keyboard、VoiceOver、44pt操作面、focusとtoolbar代替入口。
- 本文所有権、IME、sessionをまたぐ操作の拒否、編集操作のUndo。
- 状態表示と実処理の一致、失敗時の原稿保持、空状態からの実在する操作。
- 本書のtoken／余白／階層と [iOSの操作契約](IOS.md) に対する回帰。

色・配置の微調整は既存規約内で進める。外観既定、機能階層、保存／同期の意味を変える場合は製品判断として [DECISIONS.md](DECISIONS.md) を更新する。

サムネイルの設定対象は作品・人物・世界観ノートだけ（D-104）。上記寸法・形状・表紙の影を共用し、人物の8pt識別色dotは画像と併存する。一覧画像はVoiceOverから隠し、詳細画像は「〇〇の画像」、設定／置換／削除は対象が分かるlabelを付ける。切り抜きsheetは中央cropを初期値に、対象形状のmask・pan・pinch（Macはscrollも）・拡大率sliderを使う。

## 競合と履歴の内容表示

競合はiOS／macOS共通の専用sheetで「この端末の版」「サーバーの版」の2択にする。各版は最終保存日時（今日／昨日、またはM月d日 HH:mm）、差し替え可能な端末ラベル、差分の1行を示す。変更話が複数なら文字数差が最大の1話と「ほかN件」だけを示し、「中身を見る」で変更話一覧→読み取り専用本文へ進む。日時が取得できない場合は「保存日時不明」、版が未取得なら差分は「未取得」とし、内容を推測しない。

選択で本文が空または相手の半分以下になる話は1回確認する。操作中はsheet全体とdismissを無効化し、「後で確認」後も同期欄から再表示できる。選ばなかった版は履歴に残る。解決queue後の通知は8秒間「元に戻す」を示し、未取得なら「履歴を開く」にする。元に戻すは既存restore経路を使い、サーバー版の反映待ちはdocument gate外で最大30秒待つ。未反映・復元失敗は履歴への入口を残す。

履歴行は時刻・理由と直前の版からの差分を示す。自動保存のまとめは最古の1つ前→最新の差分。「現在」と、既存の競合・保全記録から判定できる「競合で選ばなかった版」を添える。復元確認には現在版との差分と「中身を見る」を置く。要約は表示時に非同期計算し、snapshot ID対でメモリに保持する（最大256組、account scope変更で破棄）。本文の変更objectと話名・配列順の必要なcontextだけをローカルで読み、原稿全体や資料は読み込まない。
