# NovelWriter デザイン言語(STYLE.md)

NovelWriter の見た目と手触りの唯一の正。**UI を触るすべての PR はこの文書に従うこと**(AGENTS.md 参照)。
形式は [awesome-design-md](https://github.com/VoltAgent/awesome-design-md) の DESIGN.md 構成を借用し、中身はネイティブ macOS(SwiftUI + AppKit)前提で定義する。Web の流儀(固定 hex の多用、大きな drop shadow、独自コントロール)は持ち込まない。

## 1. ビジュアルテーマ

**「夜の書斎」**。長時間の執筆に集中できる、暗く静かで、文具のように控えめな道具。

- 主役は常に本文テキスト。UI は一歩引く(彩度の高い色・強い装飾・過剰なアニメーションを使わない)
- **ネイティブ macOS ファースト**: 標準コントロール・セマンティックカラー・システム素材を最優先。カスタム描画は「標準で表現できない場合」の最終手段
- **ダークテーマを既定かつ主対象**にする。ライトテーマ個別対応は当面スコープ外。ただし将来のため、固定色の乱用ではなくトークンとセマンティックカラーを使う
- 画面は Project Sidebar / Outline / Editor / AI Assistant Panel の4領域ワークベンチとして扱い、本文の横幅を最優先する

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
| `surface` | `#202126` | Outline / Editor chrome / AI panel の面 |
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
- 固定幅の基準: Project Sidebar 初期 200pt(184〜224pt) / Outline 初期 360pt(224〜440pt) / AI panel collapsed 28pt / AI panel expanded 280pt(240〜360pt) / プロットのレーン幅 260pt / キャラ一覧 280pt(最小 240pt)
- Editor は常に最も広い領域にする。幅不足時は Outline を先に縮め、本文の最小可読幅を守る
- Workbench toolbar はシステムの高さ・padding・overflow に任せ、独自の固定高さや2段目を作らない
- Outline系paneは`.thinMaterial`を共通surfaceとし、背面のwindow surfaceがわずかに見える状態を保つ。不透明な`.bar`への統一は禁止
- フォームは `.formStyle(.grouped)` に統一

## 5. コンポーネント規約

- **ボタン**: 主アクション(ダイアログの実行など)= `.borderedProminent`、通常 = `.bordered`、ツールバー・行内 = `.borderless` + アイコン。破壊的操作は `role: .destructive` を必ず付ける
- **Project Sidebar**: アイコン + ラベル。選択は OS 標準の sidebar selection を優先。常設説明文を置かず、ラベルは短い名詞にする
- **Outline**: 行は「タイトル + メタ情報」の2段構成。メタ情報は文字数・更新状態・小さなアイコンまで。検索バーは通常非表示で、表示時も一覧を押し下げすぎない。Project Sidebarを含むOutline背景は共通のtranslucent materialとする
- **Workbench toolbar**: [UIREVISION.md](UIREVISION.md) / [TOOLBAR.md](TOOLBAR.md) に従い、Project Sidebar 上は標準開閉、Outline上はpane固定のsection追加、Editor上は話追加・補助操作・右端の話内検索とする。保存状態と章タイトルを重複表示しない
- **AI Assistant Panel**: collapsed はステータスバー、expanded はチャット入力・提案一覧・選択テキスト操作の3領域。入力欄は下端に固定し、本文領域を覆わない
- **カード(プロットボード)**: 背景 `.background(.quaternary.opacity(0.5))` 相当の淡い面 + `.separator` の hairline 枠 + 角丸 8pt。カードは章レーンの囲いを持たず横方向へ連続配置する。**通常時に影を付けない**(影はドラッグ中のみ、控えめに)
- **リスト行**: 標準の `List` 選択スタイルを使う(独自ハイライトを作らない)。2行構成は「本文 `.body` + サブ `.caption` secondary」
- **空状態**: 必ず `ContentUnavailableView` を使い、文言は「〜がありません」+ 次の一歩(例:「右上の + から章を追加できます」)の2文構成
- **バッジ・カウント**: 数字は `.caption` + secondary。未回収数など注意を引くものだけ `warning` トークン

## 6. 深さ・階層

- 階層はまず**素材**で表現する: Project Sidebar / Outline = `.thinMaterial`、AI collapsed status bar = `.bar`、一時 UI(ポップオーバー)= 標準のまま
- 影は「浮いている最中」(ドラッグ中のカード等)専用。常設の drop shadow は禁止
- 境界線は `.separator` の hairline(1px)。太い枠線・二重枠を使わない

## 7. インタラクションと状態

- 選択・フォーカスリングは OS 標準に任せる(消さない・作らない)
- ドラッグ中: 元位置は `opacity 0.4`、持ち上げたカードは軽い影。ドロップ先レーンは `accent` の淡いハイライト
- アニメーション: `.snappy`(0.2s 目安)に統一。バウンスや 0.5s 超の演出は禁止
- キーボード: 一覧系は Enter=編集 / ⌫=削除(確認付き)を共通作法にする
- Project Sidebar: Cmd+1〜8 でセクション移動
- Outline: Cmd+F で検索バーをピン留め表示、Esc で閉じる。上方向スクロール時の検索バー表示は補助動作であり、キーボード導線を必ず残す
- Workbench toolbar: 編集操作は標準の「ツールバーをカスタマイズ…」で追加・削除・並べ替え可能にする。toolbar を唯一の機能入口にしない
- AI Assistant Panel: Cmd+J など既存ショートカットと衝突しないキーで開閉。expanded 中も Esc で入力フォーカス解除できる

## 8. 文言(日本語 UI ライティング)

- ラベルは簡潔な体言止めまたは「〜を追加」形(例: 章を追加 / スナップショットを保存)
- 続きの入力・選択が必要な操作は三点リーダー「…」を付ける(例: 資料を取り込む…)
- 確認ダイアログのボタンは動詞(削除 / キャンセル)。「はい/いいえ」禁止
- 説明文・空状態は「です・ます」体。感嘆符は使わない

## 9. AI エージェント向けチェックリスト(UI を触る PR の提出前に確認)

- [ ] セマンティックカラー以外の色は、本文書のトークン(canvas / surface / surfaceRaised / border / accent / warning / success / danger / キャラ10色)だけか
- [ ] ダークテーマでコントラストを確認したか(固定 hex の白・黒・グレーが紛れていないか)
- [ ] 余白・サイズは 8pt グリッドに乗っているか
- [ ] フォントはテキストスタイル経由か(size 直指定なし)。数値表示に `.monospacedDigit()` があるか
- [ ] Project Sidebar / Outline / Editor / AI Assistant Panel の幅と優先順位が崩れていないか
- [ ] Project Sidebarを含むOutlineが共通のtranslucent materialで、Reduce Transparencyでも読めるか
- [ ] 上部が一段の native toolbar で、Sidebar 開閉 / 作品名 + 章数 / 編集操作 / 右端検索の既定配置になっているか
- [ ] カスタマイズ可能な toolbar 操作すべてに、メニューまたは文脈メニューの代替入口があるか
- [ ] AI Assistant Panel を閉じた状態でも保存状態・文字数・AI状態が読めるか
- [ ] 空状態は `ContentUnavailableView` + 規約どおりの文言か
- [ ] 常設の影・独自ハイライト・0.5s 超のアニメーションを追加していないか
- [ ] 破壊的ボタンに `role: .destructive` と確認ダイアログがあるか
- [ ] 文言が 8章 の規約(体言止め・…・動詞ボタン・です・ます)に沿っているか

## 変更の手続き

トークンや規約を変えたいときは、この文書を先に更新する PR を出し、DECISIONS.md に理由を記録してから実装する(場当たりの色・余白追加をしない)。
