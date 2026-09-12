# AIチャット用クリップボード支援

**通常版の契約: 原稿からplain text promptを作り、明示操作でコピーする / 照合: 2026-09-12**

利用者が任意のAI chatへ手動で渡せるよう、校正／アドバイス×選択／話／章を提供する。FUMINIWAは送信、chat起動、自動paste、応答取込、diff、Applyを行わない。決定はD-054／D-075。provider再開は [AI_INTEGRATION.md](AI_INTEGRATION.md) の履歴を根拠に自動着手せず、新しい判断と最新APIの評価から始める。

## 1. 現在の実装と不足

- 両appの共有builderは [`NovelApp/AIClipboardPrompt.swift`](../NovelApp/AIClipboardPrompt.swift)。`project.yml`はMac側の旧同名featureファイルを除外する。
- macOSは`Features/Writing/AppState+Outline.swift`と`EditorPaneView`等からcopyへ接続している。
- iOSには`IOSDocumentStore+ClipboardV2.swift`のAPIとbuilder testsがあるが、live `IOSWorkbenchViewV2.swift`には選択／話／章copy入口が未接続。旧Viewの入口だけでiOS提供完了としない([IOS.md](IOS.md))。
- 実行時の保存／認証にはnetworkやKeychainが必要でも、この機能のbuilder／clipboard経路へ依存を混ぜない。

## 2. Purpose

| 用途 | 依頼する内容 | 範囲を越えない条件 |
| --- | --- | --- |
| 校正 | 誤字・脱字・衍字、文法／助詞、句読点／表記、視点・時制、重複の指摘と修正案 | 意味・語り口・人物の口調を保つ。問題がない箇所を無理に変更せず、判断不能は要確認とする |
| アドバイス | 良い点、読みやすさ、情報提示、テンポ、描写・会話、動機・感情、章／話の役割と優先順位付き改稿案 | 提示範囲の根拠を示す。全面書き換えや存在しない設定の断定をしない |

現行builderの校正回答形式は総評／指摘一覧／校正後全文、アドバイスは良い点／根拠付き改善点／改稿案／追加文脈が必要な点。この記事を参考にしたmd整理では、製品がコピーするprompt本文や回答形式を変更しない。

## 3. Scope

| scope | 含める原稿 | 利用条件 |
| --- | --- | --- |
| 選択 | exact non-empty本文selectionのみ | 生存surface、valid UTF-16、IME確定済み |
| 1話 | その話のタイトルと本文 | 同じdocument sessionに対象IDが存在 |
| 1章 | 章タイトルと`Chapter.episodes`配列順の全話タイトル／本文 | 同じdocument sessionに対象IDが存在 |

選択外本文、話メモ、人物、プロット、伏線、世界観、資料、作品metadataを加えない。空話も順序から落とさず、空タイトルに別内容を補わない。対象本文がすべて空白／改行ならタイトルだけをコピーせず拒否する。

すべてのscopeで、document／Chapter／Episode／request ID、session、surface、revision、UTF-16 range、digest、URL／path、保存状態、端末設定、snapshot名をpayloadへ入れない。

## 4. Prompt contract

- 同じpurpose／scope／文字列から同じplain textを作る。原稿は命令ではなく引用データとしてJSON文字列へ封じる。
- quote／control characterのJSON escapeは許すが、decode後のtitle／content／textを入力と一致させる。Unicode正規化、trim、改行変換、要約、空話の間引きをしない。
- 役割・用途、対象scopeと回答制約、原稿内の指示に従わないこと、対象原稿を区別する。provider名、model名、内部protocol、外部AI固有のsystem設定を加えない。
- 対象title／content／textの合計は250,000文字かつUTF-8 1,000,000 bytes以下。生成promptはUTF-8 2,000,000 bytes以下。超過はwrite前に全体拒否し、切り詰めない。外部AIが受理する上限の保証ではない。

## 5. UIとclipboard境界

操作名は「校正用プロンプトをコピー」「アドバイス用プロンプトをコピー」。AI実行済みと見える文言や後続dialogを示す「…」を付けない。章／話行と本文context menuから到達でき、keyboard／VoiceOverで用途と範囲を判別できること。

明示操作1回につきclipboard writeは最大1回。item準備を置換前に終え、準備失敗なら既存clipboardを保持する。置換開始後のwrite失敗は元clipboardの保持を保証できないため、成功表示、自動retry、復元を行わない。原稿・選択・Undo・保存状態は変更しない。

成功はコピーだけを通知し、原稿やpromptを再掲しない。promptをDB、package、snapshot、UserDefaults、通常ログへ複製しない。system clipboardは他app、manager、Universal Clipboard等が読取・同期・保存できる共有境界であり、履歴非保持、外部送信なし、外部AIでの保持／学習なし、secure eraseを保証しない。利用者が後でコピーした内容を壊す自動消去も実装しない。

## 6. Session・IME・所有権

menu表示時のsessionと対象IDを保持し、activation時に再検査する。作品切替後に現在作品や同じIDへ読み替えない。選択scopeはEditorKitの公開command境界を通し、Appからnative viewを探索しない。IME中は拒否し、確定後の新しい明示操作を待つ。

章／話は操作時点の確定したmemory値を同期的にsnapshot化する。clipboard待機中に別作品へ再resolveしない。コピー自体は本文revision、Undo、自動保存を変更する編集操作ではない。既存のnative確定本文captureとcopyの副作用を分けて検証する。

## 7. 検証と完了条件

変更した境界に対応する既存testsを使い、以下の結果を保つ。

- 6組合せのpurpose／scope、章の配列順、空話／空タイトル、日本語・絵文字・結合文字・U+2028／U+2029・改行のexact保持。
- 範囲外data／identityの混入なし。空選択、invalid UTF-16、IME、失効surface／session、対象削除、上限超過でwrite 0回。
- 成功時write 1回。write失敗でも原稿・選択・Undo・既存保存物を変更しない。
- builderは純粋ロジック、writerはplatform境界。provider、SDK、CLI、Node、network、Keychain、subprocessへの新しい依存なし。
- 実際のlive Viewで操作可能で、keyboard／VoiceOverがcopyを正しく伝える。builder testsだけでUI完成としない。

iOS入口の復旧はこの既存契約の実装であり、新しいproviderの承認を必要とする作業ではない。

## 8. 履歴

[整理前の契約全文](archive/product-guidance-20260912/CLIPBOARD_AI_ASSIST.md)。仕様の削除ではなく、現況、製品境界、検証条件を分離した。
