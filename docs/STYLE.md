# ふみにわ デザイン言語(STYLE.md)

ふみにわ（FUMINIWA）の見た目と手触りの唯一の正。**UI を触るすべての PR はこの文書に従うこと**(AGENTS.md 参照)。UI-REF-1〜6のWorkbench再調整は完了済みで、以後のUI変更も本書の規約を継続して適用する。
形式は [awesome-design-md](https://github.com/VoltAgent/awesome-design-md) の DESIGN.md 構成を借用し、中身はネイティブmacOS（SwiftUI + AppKit）とiOS / iPadOS（SwiftUI + UIKit）前提で定義する。Web の流儀(固定 hex の多用、大きな drop shadow、独自コントロール)は持ち込まない。

## 1. ビジュアルテーマ

**「静かな書斎」**。長時間の執筆に集中でき、文具のように控えめな道具。Dark外観では従来の「夜の書斎」、Light外観では紙と朝光を思わせる「朝の書斎」として、同じ情報階層を保つ。

- 主役は常に本文テキスト。UI は一歩引く(彩度の高い色・強い装飾・過剰なアニメーションを使わない)
- **ネイティブUIファースト**: 標準コントロール・セマンティックカラー・システム素材を最優先。カスタム描画は「標準で表現できない場合」の最終手段
- Sidebar、Outline、toolbar、form等のchromeは、macOSではシステムLight／Dark外観への追従を既定とする。iOS / iPadOSはD-057により初回だけDarkを既定とし、いずれも設定からシステム追従／Light／Darkを選び直せる。特定外観だけで成立する固定色UIにしない
- 本文エディタのキャンバスはchromeと独立した利用者設定とし、既定は従来どおり「夜の書斎」の暗色キャンバスにする。システム外観を変えても利用者の本文配色を勝手に上書きしない
- 画面は Project Sidebar / Outline / Editor と下部status barのワークベンチとして扱い、本文の横幅を最優先する。未実装AI用の領域は予約表示しない(D-040)
- macOSはD-063のcloud-first chooserから作品へ入る。端末内のapp-private作業コピー、内部path、Finder入口を通常UIへ見せず、外部`.novelpkg`は「作品を取り込む…」、portable copyは「書き出す…」だけから扱う
- iOS / iPadOSは作品棚から作品ホームへ入り、作品情報／執筆／プロット／登場人物／世界観／資料／設定を選んでから各Outline / Detailへ進む。作品棚はapp-private作業コピーだけを表示し、外部providerは標準pickerへの入口として表現する(D-057 / D-058)

## 2. カラー

### 原則

1. **まずセマンティックカラー**: `Color.primary` / `.secondary` / `Color(nsColor: .textBackgroundColor)` / `Color(uiColor: .systemBackground)` / `.separator` 等。各OSのアクセシビリティ設定に追従しやすくする
2. **hex 直書きは本文書で定義したトークンのみ**。それ以外の固定色をコードに書いたら規約違反
3. 彩度の高い色は「意味のある小さな面積」(ドット、バッジ、アクセント)にだけ使う。大きな面をブランドカラーで塗らない
4. 暗色はニュートラルを基本にし、藍はアクセントに限定する。画面全体を青紫の単色グラデーションにしない

### トークン

| トークン | Dark | 用途 |
|---|---|---|
| `canvas` | `#171719` | ワークベンチ全体の最背面。直接指定はルート付近のみ |
| `surface` | `#202126` | Dark時の面の参考値。通常のchromeはシステム素材を使う |
| `surfaceRaised` | `#292A30` | ポップオーバー、選択中カード、入力欄の一段上の面 |
| `border` | `#3A3B42` | hairline 境界。基本は `.separator` を優先 |
| `accent`(藍) | `#8CA7DF` | 選択・リンク・主ボタン。AssetsのAccentColorまたは各platformのpalette tokenに登録 |
| `warning` | `#E8A54A` | 未回収の伏線、注意バッジ |
| `success` | `#7FBF8A` | 回収済み・完了表示(控えめに) |
| `danger` | `#E07A7A` | 削除など破壊的操作の補助表示。ボタン自体は `role: .destructive` を優先 |

### キャラクターカラー(プリセット10色)

キャラの識別ドット・チップ用。ユーザーが ColorPicker で任意色も選べるが、既定の候補はこの10色(ダーク背景とのコントラストを確認する):

`#C25450`(紅) `#C97F3D`(柿) `#B89A3A`(芥子) `#5B9160`(松) `#4E9091`(青磁) `#5077B0`(縹) `#6A6FB2`(藤紫) `#8E6AA8`(菖蒲) `#B0628C`(梅紫) `#8A7A6A`(胡桃)

- 表示は 8pt の円(`Circle().frame(width: 8)`)を基本とし、面で塗らない

## 3. タイポグラフィ

### UI(システムフォントのみ)

| 場所 | スタイル |
|---|---|
| ワークベンチ各領域のセクション見出し | `.headline` |
| 本文・フォーム | `.body` |
| リストのサブ情報・ステータスバー | `.caption` + `.secondary` |
| 文字数などの数値 | `.monospacedDigit()` を必ず付ける(桁変動でガタつかせない) |

- カスタムフォントサイズの直指定(`.font(.system(size: 13))` 等)は禁止。テキストスタイルを使う

### エディタ本文(EditorKit)

- 既定: **ヒラギノ明朝 ProN 16pt、行間 1.5、本文色 `#E8E6DF`、背景色 `#171719`**(小説執筆の既定として明朝。設定でフォント種類/サイズ/行間/本文色/背景色を変更可能にする)
- `textContainerInset`: 左右 16pt / 上下 16pt
- 本文末尾の下には常に 96pt の執筆用表示余白を確保する。本文へ改行や空白文字を追加せず、スクロール領域だけを広げる
- 本文の最大幅: 未設定時は制限なし(中央寄せなし)。制限なし / 700pt / 900pt は設定で切り替えられる
- 話メモなど補助テキスト入力はシステムフォントのまま(明朝は本文だけの特別扱い)

## 4. スペーシングとレイアウト

- **8pt グリッド**(例外的に 4pt 刻みまで可)。マジックナンバー(7, 13, 18…)禁止
- ウィンドウ・ペインの外周余白: 20pt / グループ間: 16pt / グループ内: 8pt
- 角丸: カード・ポップオーバー内パネル = 8pt、小さなチップ = 4pt。それ以外の角丸を発明しない
- 固定幅の基準: Project Sidebar 初期 200pt(184〜224pt) / Outline 初期 360pt(224〜440pt) / 下部status bar 28pt / プロットのレーン幅 260pt / キャラ一覧 280pt(最小 240pt)
- macOS起動chooserは最小720×520ptの同一window内に、上から小さなアプリアイコン／名称、横並びの「作品を取り込む…」「新しい作品」、単一の「iCloudの作品」Listを置く1 pane構成とする。iconは56ptを基準とし、version、local path、保存場所、Finder操作、recent専用sidebar、選択detail、巨大なbrand card、複数の浮いたpanelを置かない
- Editor は常に最も広い領域にする。幅不足時は Outline を先に縮め、本文の最小可読幅を守る
- Workbench toolbar はシステムの高さ・padding・overflow に任せ、独自の固定高さや2段目を作らない
- iOS Editorは本文面積を優先し、保存状態を上部のnative toolbarへ置く。重複する「本文」見出し、話タイトル入力、文字カウンター、独立した下部status barを常設しない
- iOSの執筆補助バーはEditor直下に置き、ソフトウェアキーボード表示中はIME直上へ追従する。バーとsafe areaの背景は本文キャンバスと同じ不透明色にし、chrome用materialで本文を分断しない。4操作は各44pt以上のhit targetを持つ
- Outline系paneは`.thinMaterial`を共通surfaceとし、背面のwindow surfaceがわずかに見える状態を保つ。不透明な`.bar`への統一は禁止
- detail chrome(見出しバー、フォーム背面、GroupBox周辺)も`workbenchGlassChromeStyle()`(=`.thinMaterial`)へ寄せる。原稿および世界観ノートの`EditorView`背景だけは不透明キャンバスを維持する
- 執筆Outlineは`OutlineContainerView`全体へglassを付け、内側Listは`workbenchOutlineListStyle()`だけを使い二重materialを避ける
- フォームは `.formStyle(.grouped)` を設定などシステムフォームに使う。作品情報・人物・世界観の長文入力は共通のLabeled Field部品を使い、ラベルと入力の間隔8pt、長文の内側inset 8ptを守る
- 作品情報と設定はOutline列を持たない(Sidebar + Detailの2列)。世界観はノート一覧Outline + 本文Detailの3列とする(D-032)

## 5. コンポーネント規約

- **ボタン**: 主アクション(ダイアログの実行など)= `.borderedProminent`、通常 = `.bordered`、ツールバー・行内 = `.borderless` + アイコン。破壊的操作は `role: .destructive` を必ず付ける
- **Project Sidebar**: アイコン + ラベル。選択は OS 標準の sidebar selection を優先。常設説明文を置かず、ラベルは短い名詞にする
- **Outline**: 通常の行は「タイトル + メタ情報」の2段構成。執筆Outlineの章Disclosureだけは、章名・話数・文字数・現在行の保存状態を横一列へ収めるcompact行とし、章名以外を末尾へ固定する。章label全体を開閉のhit targetにする。検索バーは通常非表示で、表示時も一覧を押し下げすぎない。Project Sidebarを含むOutline背景は共通のtranslucent materialとする
- **Workbench toolbar**: [UIREVISION.md](UIREVISION.md) / [TOOLBAR.md](TOOLBAR.md) に従い、Project Sidebar 上は標準開閉、Outline上はpane固定の章・人物・ノート・資料追加、Editor上は左端の話追加・中央の補助操作・右端の話内検索とする。保存状態と章タイトルを重複表示しない
- **Workbench status bar**: macOSでは保存状態、保存失敗時の再試行、選択話／作品全体の文字数、検索不一致だけを表示する。展開、AI入力、未実装機能へのクリック導線を持たせない。iOS EditorはD-058によりstatus barを常設せず、保存状態を上部へ移し、文字数を重複表示しない
- **iOS Editor accessory**: `……` / `――` / `ルビ` / `傍点`の短いlabelを横並びにし、本文キャンバスと同じ背景を使う。選択が必要な操作は無効状態を見た目とVoiceOver valueの両方で伝え、toolbarだけを唯一の入口にしない
- **Startup / Document Selection / Recovery**: `loading`では作品を準備していることだけを静かに示し、編集操作を出さない。macOSの`documentSelection`は上部に小さなアプリアイコン／名称と「作品を取り込む…」「新しい作品」、その下に見出し「iCloudの作品」と標準Listを1つだけ置く。各行は作品名を主、更新日時とtruthfulなiCloud／端末内状態をcaptionにし、local path、保存場所、Finder表示、別detail paneを置かない。malformed remote rowはその行だけを隔離してvalid／local行を残す。以前確認済みsame account scopeの一時offlineではcached remote-only行を残してdownload不可にし、`accountRequired`／unscoped／mismatchではlocal packageのないremote rowとtitleを表示しない。packageのないApp `remoteOpenPending` rowも`accountRequired`／different accountでは棚から除外する。cached exactはofflineでも開ける。「新しい作品」と「作品を取り込む…」はnetwork／account未確認またはremote catalog refresh失敗だけを理由に無効化せず、local install後はsame-scope一時offlineとunscoped local-onlyを別状態で表示する。作成予定snapshotのexpected package attestationをreservation前にdurable化できない新規／Import、legacy package／expected attestation nil reservation、staging read-back不一致は成功行へ出さずquarantineし、stagingを破棄して再起動後も利用可能な作品として推測採用しない。`recovery`でも内部working copyのpath／Finder入口を出さず、原因、再試行、作品を取り込む、明示的新規作成を標準button階層で提示する。外部原本に対する失敗だけはbasenameを表示してよいが、full pathは表示へ出さない。diagnostic logへapp-private path／WorkIDを出さない
- **Startup sync truth**: local packageとaccount-scoped remoteの一致する行だけ`checkmark.icloud`と「iCloudと同期済み」を使う。same-scopeのlocal変更が未確認なら「このMacに保存済み、iCloudへ保存中」、以前確認済みscopeの一時offlineなら「接続後に同期」とする。catalog読込失敗中のlocalPendingは「接続後に同期」とせず、明示の「iCloudに保存」で再送できることを示す。競合は「内容の確認が必要」とする。資料／snapshot履歴まで完全backup済みと読める文言を使わない。revision／branch／merge／journal／leaseを通常画面へ出さない
- **WorkSync local recovery gate**: 通常chooser／Recoveryのactivationに続くlocal package検証中は、不透明なsemantic backgroundで背後のWorkbenchを知覚・操作不能にし、確認中はlabel付き`ProgressView`、choiceが必要なら`ContentUnavailableView`で「変更の確認が必要です」と「変更を確認」を示す。通常のcloud衝突は全画面gateへ流用せず、この端末／iCloud／両方を別作品として残す、の短い3択にする。統合案は出さない
- **カード(プロットボード)**: 背景 `.background(.quaternary.opacity(0.5))` 相当の淡い面 + `.separator` の hairline 枠 + 角丸 8pt。カードは章レーンの囲いを持たず横方向へ連続配置する。**通常時に影を付けない**(影はドラッグ中のみ、控えめに)
- **リスト行**: 標準の `List` 選択スタイルを使う(独自ハイライトを作らない)。2行構成は「本文 `.body` + サブ `.caption` secondary」
- **空状態**: 必ず `ContentUnavailableView` を使い、文言は「〜がありません」+ 次の一歩(例:「右上の + から章を追加できます」)の2文構成。macOS起動chooserの空Listは「作品がありません」／「新しい作品を作るか、作品パッケージを取り込めます。」とし、account未設定／一時offline／読込失敗を同じ空状態に畳み込まない
- **バッジ・カウント**: 数字は `.caption` + secondary。未回収数など注意を引くものだけ `warning` トークン

## 6. 深さ・階層

- 階層はまず**素材**で表現する: Project Sidebar / Outline / detail chrome = `.thinMaterial`、status bar = `.bar`、一時 UI(ポップオーバー)= 標準のまま。本文キャンバスだけ不透明
- 影は「浮いている最中」(ドラッグ中のカード等)専用。常設の drop shadow は禁止
- 境界線は `.separator` の hairline(1px)。太い枠線・二重枠を使わない
- ラベルと入力が横に張り付いて見える配置を避ける。長文は縦積み(ラベル→8pt→入力)にする

## 7. インタラクションと状態

- 選択・フォーカスリングは OS 標準に任せる(消さない・作らない)
- ドラッグ中: 元位置は `opacity 0.4`、持ち上げたカードは軽い影。ドロップ先レーンは `accent` の淡いハイライト
- アニメーション: `.snappy`(0.2s 目安)に統一。バウンスや 0.5s 超の演出は禁止
- キーボード: 一覧系は Enter=編集 / ⌫=削除(確認付き)を共通作法にする。本文選択の対象にしないDisclosure headerは、同じ操作へ到達できるメニュー項目を必ず持つ
- macOS起動chooserの「iCloudの作品」Listは編集一覧ではないため、矢印キーで選択し、**Listがfocus中のときだけ**Returnで選択作品を開く。double clickでも開けるがsingle clickだけでは開かない。上部action buttonがfocus中のReturnはbutton自身へ渡す。`Cmd+N`は新規作品、`Cmd+O`は「作品を取り込む…」、`Cmd+Shift+S`は「書き出す…」へ到達させる。List focus中のDeleteは確認付きでこのMacの作業コピーを外す。local-only／localPendingかつsigned-in（catalog失敗を含む）は行の「iCloudに保存」とcontext menuの複製／削除を出す。automatic adoptの導線は置かない
- Project Sidebar: Cmd+1〜7 でセクション移動
- Outline: Cmd+F で検索バーをピン留め表示、Esc で閉じる。上方向スクロール時の検索バー表示は補助動作であり、キーボード導線を必ず残す
- Workbench toolbar: 編集操作は標準の「ツールバーをカスタマイズ…」で追加・削除・並べ替え可能にする。toolbar を唯一の機能入口にしない
- 保存: 未結線の作品では`Cmd+S`はFileメニューの「保存」と一致させ、`ready`かつWorkSync local recovery gate中でない作品だけを同じ保存直列化経路で保存する。iCloudへ結んだ作品では`Cmd+S`は「iCloudと同期」と一致し、同じlocal保存のあと明示同期する(D-073)。自動保存・終了前保存・話切替はlocalだけ

## 8. 文言(日本語 UI ライティング)

- ラベルは簡潔な体言止めまたは「〜を追加」形(例: 章を追加 / スナップショットを保存)
- 続きの入力・選択が必要な操作は三点リーダー「…」を付ける(例: 資料を取り込む…)
- エディタ下部のアクセサリバーは省スペースのため、続きの入力があっても「…」を付けない
- 確認ダイアログのボタンは動詞(削除 / キャンセル)。「はい/いいえ」禁止
- 説明文・空状態は「です・ます」体。感嘆符は使わない
- macOS起動chooserの見出しは「iCloudの作品」とする。「最近使った作品」「このデバイスの作品」、local path／保存場所、Finder用語を通常導線へ混ぜない。「iCloudと同期済み」はD-063のexact local attestation＋remote receiptを確認した行にだけ使い、local pending、remote-only、offline、account mismatch、破損を同じbadgeへ畳み込まない

## 9. AI エージェント向けチェックリスト(UI を触る PR の提出前に確認)

- [ ] セマンティックカラー以外の色は、本文書のトークン(canvas / surface / surfaceRaised / border / accent / warning / success / danger / キャラ10色)だけか
- [ ] システム追従／明示Light／明示Darkの各設定でコントラスト、文字、separator、素材、Reduce Transparencyを確認したか。iOSのDark初回値以外で利用者の選択を上書きしていないか
- [ ] 余白・サイズは 8pt グリッドに乗っているか
- [ ] フォントはテキストスタイル経由か(size 直指定なし)。数値表示に `.monospacedDigit()` があるか
- [ ] Project Sidebar / Outline / Editor / status bar の幅と優先順位が崩れていないか
- [ ] Project Sidebarを含むOutlineが共通のtranslucent materialで、Reduce Transparencyでも読めるか
- [ ] 上部が一段の native toolbar で、Sidebar 開閉 / 作品名 + 章数 / 編集操作 / 右端検索の既定配置になっているか
- [ ] カスタマイズ可能な toolbar 操作すべてに、メニューまたは文脈メニューの代替入口があるか
- [ ] status barが保存状態・話／全体文字数・検索不一致だけを正確に示し、未実装機能の入口を含んでいないか
- [ ] iOS Editorでは保存状態が上部にあり、重複する本文見出し／話タイトル入力／文字カウンターがなく、執筆補助バーの背景とsafe areaが本文キャンバスへ連続しているか
- [ ] `……` / `――` / `ルビ` / `傍点`が44pt以上、VoiceOverで識別可能、IME／stale selection時に本文を変更せず、Undo 1回で戻せるか
- [ ] Loading / Document Selection / Recovery中に編集・保存可能なWorkbenchが露出せず、chooserとRecoveryの導線がキーボードとVoiceOverで使えるか
- [ ] macOS chooserが1 paneの「iCloudの作品」Listを使い、path／Finder／detail paneを出していないか。System／Light／Darkで固定色や二重materialがなく、refresh中もcached rowsが消えないか
- [ ] startup各行が作品名をlabel、正確なlocal／remote状態をvalue、利用可能な開き方をhintとして読み上げるか。省略タイトルは「…」とVoiceOverで分かり、remote-only offline／破損に再接続だけで必ず開けるようなhintを出していないか。account mismatchは検証済みlocal packageの有無を区別しているか
- [ ] malformed remote rowだけを隔離し、catalog failure中もlocal-only新規／Importを無効化せず、different-account remote-only row／titleを表示していないか
- [ ] `accountRequired`／different accountでpackageのないApp `remoteOpenPending` rowを棚から除外し、旧scopeの存在／titleを漏らしていないか
- [ ] 新規／Importのexpected package attestationをreservation前にdurable化し、legacy package／expected attestation nil reservationとstaging read-back不一致を成功行へ出さず再起動後も採用していないか。app-private WorkID／pathを表示／diagnostic logへ出していないか
- [ ] unscoped local-only workを「接続後に同期」と表示せず、後から現れたaccountへのautomatic adopt／upload導線を出していないか。明示の「iCloudに保存」はsigned-in（catalog availableまたはtype未作成によるcatalog失敗）のlocal-only／localPendingに限り、失敗をアラートで返すか。Workbench toolbarとFileメニューからも同じ操作へ到達できるか
- [ ] iCloudへ結んだ作品で、自動保存や話切替のあとに「オフライン」「iCloudへ同期中」と出さず「この端末に保存済み」か。`Cmd+S`と「iCloudと同期」だけがsend／pullし、query失敗をオフラインと読まないか
- [ ] 作品棚の削除がこの端末の作業コピーだけを対象にし、確認と`role: .destructive`があり、CloudKit tombstoneやremote-only削除を出していないか。複製が新しいWorkIDのcopyで現在作品を切り替えないか
- [ ] `checkmark.icloud`／「iCloudと同期済み」がexact local package attestation＋account-scoped remote receiptの一致に限られ、attachment／snapshot履歴を含む完全backupを示唆していないか
- [ ] availableなcurrent catalogからacknowledged workが欠落したとき、`.cloudUnavailable`／「iCloud上の作品を確認できません」へ切り替え、checkmark／open／uploadを停止してlocal packageを保持しているか
- [ ] WorkSync local recovery中は背後の全mutationがgateされる一方、root-levelの「変更を確認」とexact review／sessionを再検査する3面choiceが操作可能か。状態が色やspinnerだけでなく文字とVoiceOver labelでも伝わるか
- [ ] 空状態は `ContentUnavailableView` + 規約どおりの文言か
- [ ] 常設の影・独自ハイライト・0.5s 超のアニメーションを追加していないか
- [ ] 破壊的ボタンに `role: .destructive` と確認ダイアログがあるか
- [ ] 文言が 8章 の規約(体言止め・…・動詞ボタン・です・ます)に沿っているか

## 10. D-063 source freeze UI証跡

D-063の単一pane「iCloudの作品」chooserとProduct Truth表示はsource complete／local automated GOである。FUMINIWA macOS full xcresult device cases 208 / 208件（top-level 203件、hosted 124件＋unhosted 79件、dynamic casesを含む）、focused Cloud＋store device cases 15件／top-level 14件、hosted Startup Cloud UI 1 / 1件とfreshな`./Scripts/check.sh`の`All checks passed`を通過し、UI test分離後のhosted `NovelAppTests`は`NovelSyncTesting`へ依存しない。Cloud／store回帰はexpected attestation先行reservationとlegacy nil隔離、packageなしpending rowのaccount隔離、acknowledged work欠落時の`.cloudUnavailable`、kill-window復旧、staging不一致非採用、catalog failure中のlocal作成、malformed／different-account row隔離、private identity log redactionを含む。実Mac AppでもComputer Useによるvisual／Accessibility tree受け入れをPASSし、安全再監査はP0／P1なしである。同期層を含む全matrixは[DEVICE_SYNC.md](DEVICE_SYNC.md) 0.13を正とする。

この証跡は現行のvisual／Accessibility treeとlocal automated behaviorを確認したもので、手動VoiceOver／Full Keyboard Access、paired native、実account／account switch、実OS process kill、署名済み実CloudKitを完了したものではない。Package Validator、External Change / Conflict、production migration／minimum-version fenceを含め、ReleaseはNO-GOのままである。

## 変更の手続き

トークンや規約を変えたいときは、この文書を先に更新する PR を出し、DECISIONS.md に理由を記録してから実装する(場当たりの色・余白追加をしない)。
