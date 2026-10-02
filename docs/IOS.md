# iOS / iPadOS

iOS / iPadOS 17以降。iPhoneは作品棚→作品ホーム→各機能へ進み、iPadは同じ操作を複数列へ展開する。通常保存は端末SQLite。[設計](DESIGN.md)の本文・保存境界と[STYLE](STYLE.md)を共用する。

## 現行の入口

| 責務 | `NovelAppIOS/`内の実装 |
| --- | --- |
| 作品棚・ホーム | `Library/IOSLibraryViewV2.swift`、`IOSProjectHomeViewV2.swift` |
| 執筆・機能navigation | `Features/Writing/IOSWorkbenchViewV2.swift` |
| 保存・選択・認証 | `DocumentLifecycle/`、`DeviceSync/`と共通v2 application |
| 原稿コピー | `DocumentLifecycle/IOSDocumentStore+ClipboardV2.swift`と共有`ManuscriptCopy` |
| AI回答保存・閲覧 | `Features/Writing/IOSDocumentStore+AssistantFeedback.swift`、`IOSAssistantFeedbackView.swift` |
| 外観・フォント | `Features/Settings/IOSSettingsViewV2.swift`、`Platform/iOS/IOSAppearance.swift` |

## 操作

- 作品棚のlocal/cached作品は端末から開く。remote-only作品は対象accountを確認して取得する。端末一覧とremote一覧の更新世代は分け、端末側の更新だけで有効なremote応答を捨てない。
- remote-only作品の取得中は棚の対象行に「作品を取り込み中…」を表示する。一時的な通信失敗は失敗した読取だけを最大2回再試行し、取得済みの履歴を最初から読み直さない。認証・account scope・データ検証の失敗は自動再試行せず、通信失敗と区別して表示する。
- 初回取り込みは[一括読取](sync/v2/download.md)で履歴と重複排除した小さなデータをまとめて受け取る。履歴件数や原稿内容は減らさず、大きな添付と旧serverは既存の検証付き個別読取を使う。
- 作品から戻る操作は標準Back。各画面に独自の「作品一覧」ボタンを常設しない。Editorを外す前に入力確定と端末保存を完了し、古い保存完了で別のnavigationを変更しない。
- 執筆・作品情報・プロット／伏線・人物・世界観・資料・感想アドバイス・設定へのrouteを持つ。履歴は作品ホームの「履歴を見る」から専用sheetのListへ開き、件数でホームの高さを増やさない。
- 本文下の補助バーは`……`／`――`／`ルビ`／`傍点`。44pt以上の操作面、IME中の拒否、選択の再検査、1回のUndoを守る。
- 「コピー」メニューは話・章、選択context menuは選択文字列をplain textでコピーする。[コピー契約](CLIPBOARD_AI_ASSIST.md)参照。
- アクセント色の「AI」からinspectorを開く。校正・感想は対象のpreview後に送信する。校正は本文へ反映でき、変更箇所を黄色で表示する。アドバイスは章・話を選んでチャットし、依頼ごとに許可した範囲を編集できる。最初の参照確認は挟まない。感想と会話・指示を保存・同期する。[AI支援](WRITING_ASSISTANT.md)参照。
- 話名変更は本文上部の話名メニューと話行の長押し。作品名変更は棚の作品行の長押し。空白だけの名前は拒否し、取得元session/accountと対象IDを確認してmetadataだけを保存する。選択作品・話やEditor世代を変えない。remote-only作品は明示操作に必要な取得後に変更する。
- 作品削除は棚の表紙・一覧の長押し「作品を削除…」、一覧のswipeから確認する。IME確定→端末保存→削除intent→開いている作品とnavigationの終了をdocument gate内で済ませ、通信はgate解放後に行う。未取得作品もダウンロードせず同じ削除APIを使い、未完了は「削除待ち・接続時に再試行」を表示する。対象の取り込み中は理由付きで無効にする。[削除契約](sync/v2/work-deletion.md)参照。
- 履歴復元と競合3択は対象WorkID/session/accountを固定し、採用前の本文を保全する。Snapshot IDの手入力は要求しない。
- 初回外観はDark、以後はSystem／Light／Darkの選択を保持する。本文のフォント・配色は独立した端末設定。

## OS境界

Filesのsecurity-scoped accessはImport / Export中だけ保持し、成功・失敗・取消で解放する。Importは原本を変えず新WorkIDへ、Exportはactive identityを変更しない。

本文の所有者はEditorKitの`UITextView`。IME確定→ローカル保存→画面切替を同じdocument operation gateで直列化する。size class変更も本文を取り外す境界として扱う。remote採用は検証済みInbox、session、account fence、世代、未保存変更を照合して行う。

domain/store/workerはNovelKitで共有し、iOS側は入力・navigation・Files・clipboard・表示を担当する。`DocumentGroup`や`UIDocument`を第二の保存所有者にしない。

## 受入待ち

コード上の接続と、署名済みiPhone / iPadでの受入は分ける。未実装事項は[CODE_HEALTH](CODE_HEALTH.md)、検証段階は[AGENTS](../AGENTS.md)。関連変更・公開受入では次を確認する。

- 狭幅・回転・Split View、VoiceOver、Dynamic Type、hardware keyboard。
- IME中の話切替・Back、補助入力のUndo、scene退避・再起動後の確定本文。
- Macとの往復、offline分岐、競合3択、履歴復元、remote-only open、account切替。

過去の実機結果はGit履歴で参照し、現在の受入完了へ流用しない。

## サムネイル

作品情報の表紙、人物詳細、世界観ノート詳細から写真（PhotosPicker）またはFilesの画像を選ぶ。対象形状の切り抜きsheetで位置・拡大率を調整後に保存する。置換・削除は画像の長押しmenuと詳細のmenuにあり、削除は確認付き。棚・人物・世界観の行は縮小画像またはSTYLEのplaceholderを表示する。[保存契約](sync/v2/thumbnails.md)。

作品ホームはWorkInfoSummary直後に「進み具合」Sectionを置く。今日の加筆量・純増、幅に収まる最大16週のカレンダー、継続と今週、目標／任意の締切、最近の到達と一覧を共通カードで表示する。カレンダーのタップはカード内の1行へ日別値を表示し、VoiceOverはグリッド全体を要約する。目標設定・変更・削除はsheetから行う。本文画面には文字数も到達通知も常設しない。

## 作品全体の検索・置換と人物の登場

執筆の章・話一覧の「執筆のメニュー」→「作品全体を検索」からList画面へ進み、searchableで本文を検索する。章→話ごとの件数・文脈、各一致の「置換に含める」を表示する。結果を選ぶと既存の話選択・保存境界を通して本文を開き、UTF-16一致範囲を選択する。下部の「N件を置換…」は置換文字列と件数を確認するsheetへ進み、「置換／キャンセル」で実行する。結果の選択・下部操作は44pt以上、標準List／Formと可変フォント、VoiceOverの対象文脈と操作説明を使う。

人物詳細の自由メモ後に「登場」Sectionを置き、話数・最初／最後、章名・話名・回数を示す。人物menuの「本文の名前を置換…」は人物名を入力した検索画面へ進む。名前変更自体は本文を変更しない。非同期計算、置換前履歴、変更話の拒否、一時的な元に戻すは[共有仕様](DESIGN.md#69-作品全体の検索置換と人物の登場)に従う。

## 表記・記号チェック（端末内）

執筆の章・話一覧にある「執筆のメニュー」→「表記をチェック」からList画面へ進む。作品全体／現在の話、会話文除外（既定OFF）を選び、「チェック」で実行する。ルール→章・話順の件数・文脈を表示し、選択で既存の話選択経路を通して指摘範囲を選ぶ。「置換…」は作品全体検索の検索欄・置換欄を入力済みで開く。無視一覧のsheetで解除でき、無視はこの端末だけに作品ごとに保存する。操作面は44pt以上、標準List・可変フォントとVoiceOverの指摘内容・操作説明を使う。読みの限界・失効条件は[共有仕様](DESIGN.md#610-表記記号チェック端末内)に従う。
