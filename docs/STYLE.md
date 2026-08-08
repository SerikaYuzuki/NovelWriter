# ふみにわ デザイン言語(STYLE.md)

ふみにわ（FUMINIWA）の見た目と手触りの唯一の正。**UI を触るすべての PR はこの文書に従うこと**(AGENTS.md 参照)。UI-REF-1〜6のWorkbench再調整は完了済みで、以後のUI変更も本書の規約を継続して適用する。
形式は [awesome-design-md](https://github.com/VoltAgent/awesome-design-md) の DESIGN.md 構成を借用し、中身はネイティブ macOS(SwiftUI + AppKit)前提で定義する。Web の流儀(固定 hex の多用、大きな drop shadow、独自コントロール)は持ち込まない。

## 1. ビジュアルテーマ

**「静かな書斎」**。長時間の執筆に集中でき、文具のように控えめな道具。Dark外観では従来の「夜の書斎」、Light外観では紙と朝光を思わせる「朝の書斎」として、同じ情報階層を保つ。

- 主役は常に本文テキスト。UI は一歩引く(彩度の高い色・強い装飾・過剰なアニメーションを使わない)
- **ネイティブ macOS ファースト**: 標準コントロール・セマンティックカラー・システム素材を最優先。カスタム描画は「標準で表現できない場合」の最終手段
- Sidebar、Outline、toolbar、form等のchromeは既定でmacOSのシステムLight／Dark外観へ追従する。設定で利用者が明示した場合だけ、アプリのchromeをLightまたはDarkへ固定できる。特定外観を無条件に強制しない
- 本文エディタのキャンバスはchromeと独立した利用者設定とし、既定は従来どおり「夜の書斎」の暗色キャンバスにする。システム外観を変えても利用者の本文配色を勝手に上書きしない
- 画面は Project Sidebar / Outline / Editor と下部status barのワークベンチとして扱い、本文の横幅を最優先する。未実装AI用の領域は予約表示しない(D-040)

## 2. カラー

### 原則

1. **まずセマンティックカラー**: `Color.primary` / `.secondary` / `Color(nsColor: .textBackgroundColor)` / `.separator` 等。macOS のアクセシビリティ設定に追従しやすくする
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
| `accent`(藍) | `#8CA7DF` | 選択・リンク・主ボタン。Assets の AccentColor に登録 |
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
- 本文の最大幅: 未設定時は制限なし(中央寄せなし)。制限なし / 700pt / 900pt は設定で切り替えられる
- 話メモなど補助テキスト入力はシステムフォントのまま(明朝は本文だけの特別扱い)

## 4. スペーシングとレイアウト

- **8pt グリッド**(例外的に 4pt 刻みまで可)。マジックナンバー(7, 13, 18…)禁止
- ウィンドウ・ペインの外周余白: 20pt / グループ間: 16pt / グループ内: 8pt
- 角丸: カード・ポップオーバー内パネル = 8pt、小さなチップ = 4pt。それ以外の角丸を発明しない
- 固定幅の基準: Project Sidebar 初期 200pt(184〜224pt) / Outline 初期 360pt(224〜440pt) / 下部status bar 28pt / プロットのレーン幅 260pt / キャラ一覧 280pt(最小 240pt)
- Editor は常に最も広い領域にする。幅不足時は Outline を先に縮め、本文の最小可読幅を守る
- Workbench toolbar はシステムの高さ・padding・overflow に任せ、独自の固定高さや2段目を作らない
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
- **Workbench status bar**: 保存状態、保存失敗時の再試行、選択話／作品全体の文字数、検索不一致だけを表示する。展開、AI入力、未実装機能へのクリック導線を持たせない
- **Startup / Recovery**: `loading`では作品を読み込んでいることだけを静かに示し、編集操作を出さない。`recovery`では原因を短く説明し、再試行、Finderで表示、別作品を開く、明示的新規作成を標準ボタン階層で提示する
- **カード(プロットボード)**: 背景 `.background(.quaternary.opacity(0.5))` 相当の淡い面 + `.separator` の hairline 枠 + 角丸 8pt。カードは章レーンの囲いを持たず横方向へ連続配置する。**通常時に影を付けない**(影はドラッグ中のみ、控えめに)
- **リスト行**: 標準の `List` 選択スタイルを使う(独自ハイライトを作らない)。2行構成は「本文 `.body` + サブ `.caption` secondary」
- **空状態**: 必ず `ContentUnavailableView` を使い、文言は「〜がありません」+ 次の一歩(例:「右上の + から章を追加できます」)の2文構成
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
- Project Sidebar: Cmd+1〜7 でセクション移動
- Outline: Cmd+F で検索バーをピン留め表示、Esc で閉じる。上方向スクロール時の検索バー表示は補助動作であり、キーボード導線を必ず残す
- Workbench toolbar: 編集操作は標準の「ツールバーをカスタマイズ…」で追加・削除・並べ替え可能にする。toolbar を唯一の機能入口にしない
- 保存: `Cmd+S`はFileメニューの「保存」と一致させ、`ready`な作品だけを同じ保存直列化経路で保存する

## 8. 文言(日本語 UI ライティング)

- ラベルは簡潔な体言止めまたは「〜を追加」形(例: 章を追加 / スナップショットを保存)
- 続きの入力・選択が必要な操作は三点リーダー「…」を付ける(例: 資料を取り込む…)
- エディタ下部のアクセサリバーは省スペースのため、続きの入力があっても「…」を付けない
- 確認ダイアログのボタンは動詞(削除 / キャンセル)。「はい/いいえ」禁止
- 説明文・空状態は「です・ます」体。感嘆符は使わない

## 9. AI エージェント向けチェックリスト(UI を触る PR の提出前に確認)

- [ ] セマンティックカラー以外の色は、本文書のトークン(canvas / surface / surfaceRaised / border / accent / warning / success / danger / キャラ10色)だけか
- [ ] システム追従／明示Light／明示Darkの各設定でコントラスト、文字、separator、素材、Reduce Transparencyを確認したか。利用者の選択なしにアプリ全体の外観を固定していないか
- [ ] 余白・サイズは 8pt グリッドに乗っているか
- [ ] フォントはテキストスタイル経由か(size 直指定なし)。数値表示に `.monospacedDigit()` があるか
- [ ] Project Sidebar / Outline / Editor / status bar の幅と優先順位が崩れていないか
- [ ] Project Sidebarを含むOutlineが共通のtranslucent materialで、Reduce Transparencyでも読めるか
- [ ] 上部が一段の native toolbar で、Sidebar 開閉 / 作品名 + 章数 / 編集操作 / 右端検索の既定配置になっているか
- [ ] カスタマイズ可能な toolbar 操作すべてに、メニューまたは文脈メニューの代替入口があるか
- [ ] status barが保存状態・話／全体文字数・検索不一致だけを正確に示し、未実装機能の入口を含んでいないか
- [ ] Loading / Recovery中に編集・保存可能なWorkbenchが露出せず、Recoveryの4導線がキーボードとVoiceOverで使えるか
- [ ] 空状態は `ContentUnavailableView` + 規約どおりの文言か
- [ ] 常設の影・独自ハイライト・0.5s 超のアニメーションを追加していないか
- [ ] 破壊的ボタンに `role: .destructive` と確認ダイアログがあるか
- [ ] 文言が 8章 の規約(体言止め・…・動詞ボタン・です・ます)に沿っているか

## 変更の手続き

トークンや規約を変えたいときは、この文書を先に更新する PR を出し、DECISIONS.md に理由を記録してから実装する(場当たりの色・余白追加をしない)。
