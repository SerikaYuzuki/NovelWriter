# 明示送信のAI支援（D-089）

通常版のmacOS右パネルとiOSの適応inspectorから校正は現在の1話、感想・アドバイスはチェックした話を送信する。

## 操作と設定

- toolbar「AI支援」で開閉。macOSはAI支援メニューとCmd+Jも使用できる。macOSでは右側にAI、本文下部に横並びのプロットカードを表示する。閉じると本文領域が元に戻る。
- 校正は「現在の1話」に固定する。感想・アドバイスでは「送る範囲」のチェックボックスで複数の話を選べる。章のチェックで章内を一括選択・解除し、一部選択の章は「−」で表示する。「現在の話だけ」「選択解除」も使える。未選択では送信できない。
- 「本文を確認して送信…」で対象のタイトルと本文を固定し、送信先と全文を確認して「この本文を送信」で1回送信する。校正へ切り替えても、感想・アドバイスの選択は保持するが、校正payloadは必ず現在の1話だけになる。
- 複数選択は章・話の配列順で、選択した話だけを章と話の見出し付きでまとめる。単独選択はその話のタイトルと本文を使う。編集中の話が対象内なら確定済みの最新本文を取得し、IME中は拒否する。対象外なら編集中の本文は参照しない。欠落したIDを含む範囲は一部だけで送信せず拒否する。
- macOSの校正反映は現在の1話だけに限定する。感想・アドバイスは読み取り専用Markdownとして保存する。用途・範囲・章や話の構成変更でpreviewと実行中の要求を失効させる。
- API URLはHTTPSのResponsesまたはChat Completions endpoint。初期URLはOpenAI。モデルは用途別に設定し、OpenAIの `/v1/models` の利用可能一覧を新しい順で選べる。用途別プロンプトも変更できる。
- 設定は端末内UserDefaults、キーはendpoint別のKeychain（端末限定・クラウド同期なし）。キーをUserDefaults、作品、同期DB、ログへ保存しない。
- 校正回答と未保存の回答はpanel内の一時表示。作品／話切替やpanelを閉じると取消・破棄する。macOS校正は送信時点と同じ本文・作品session・話・accountの場合のみ、JSONの全文をEditorKitのUndo可能な正規編集で反映する。IME中や本文変更後は拒否する。iOSは回答表示のみ。校正回答のDB保存、自動再送は行わない。

校正後の追加・変更文字は黄色で表示し、自動保存では消さず、明示保存のローカルcheckpoint成功後に消す。削除済み文字には色を付けられない。色はeditorの一時表示で、話切替・終了で破棄する。感想・アドバイスはMarkdown表示する。

## 実装境界

`NovelApp/WritingAssistant/`を両app targetで共有する。`AssistantManuscript`はtitle/contentだけで、対象内の編集中本文は各platformのEditorKit committed captureから取得する。その話がIME中なら拒否し、送信待ちで編集やローカル保存を止めない。preview後の編集は固定済みpayloadを変えず、別の話へ移動した場合はpreviewも失効する。

選択外の章・作品、人物、伏線、メモ、資料、内部IDを暗黙に追加しない。上限はtitle/contentの合計25万文字・UTF-8 1MB。本文をJSON文字列として囲い、本文中の指示へ従わないsystem instructionを添える。キーはpreview時ではなく明示送信時に読む。

HTTPはephemeral URLSession、cookie/cacheなし、redirect拒否、timeout付き。他社Chat Completions endpointでは`model/messages/stream:false/store:false`を送り、`choices[0].message.content`を表示する。HTTP errorのbodyを画面やログへ転記しない。`store:false`は他社サービスの保存・学習方針の保証ではない。利用料金と保存方針は送信先サービスに従う。

HTTP payloadの実装は`AssistantClient.swift`。OpenAIとResponses endpointは `instructions/input/store:false` を送り、完了したmessageのoutput_textだけを取り込む。旧Experimental target、Codex subprocess、provider SDKは復活させない。clipboard支援は独立して維持する。

## 検証

APIの実送信には利用者自身の設定が必要。開発検証で私的原稿や実APIキーを送らない。Test compositionはKeychainの読取／保存／削除と実HTTPを拒否する。payload exact保持、範囲外dataなし、endpoint制約、空・過大本文拒否、response parsingを合成データで検証する。UIの実機受入と実サービス接続は別途記録する。

校正はcontentだけを必須とするstrict JSON Schemaを要求し、非対応・未完了回答を反映しない。開閉アニメーションはReduce Motion時に無効にする。

## 感想・アドバイスの保存

用途設定のTextEditorを用途ごとに分け、切替時に前の文章が別用途の保存先へ書き戻されないようにする。感想・アドバイスに校正の既定文が完全一致で入っていた場合だけ各用途の既定文へ補正し、独自のプロンプトは保持する。送信時にも用途を明記する。

感想・アドバイスの正常応答は、左の「感想・アドバイス」に用途・対象タイトル・回答日時付きで保存する。本文は編集できないMarkdown表示。右クリック／長押しから削除を選び、確認後に削除する。保存・削除とも作品のSnapshot Sync v2に含める。APIキー・接続設定は引き続き端末限定である。

保存の実装は`NovelApp/Features/AssistantFeedback/`とiOSのstore adapterに置き、HTTP実装から分離する。既存のattachment契約を使い、SQLite checkpoint確定後に通常のremote workerへ渡す。新しい同期entityやserver migrationは追加しない。詳細は[保存形式](sync/v2/assistant-feedback.md)。作品sessionとaccountを応答の保存まで固定し、IME中や保存失敗時は回答をpanelに残して再保存を提示する。保存前にpanelを閉じると未保存回答は失われる。校正を履歴へ保存したり、感想を原稿へ反映したりしない。

## Markdownの閲覧スタイル

AIパネルと保存済みの感想・アドバイスで共通のnative Markdown表示を使う。見出し、段落、太字・斜体・リンク、引用枠、番号／箇条書き／チェックリスト、区切り線、横スクロール可能な表とコード枠に対応する。日本語の引用符を囲む`**「強調」**`が文章に連続する場合も太字で表示し、codeとescapeは保持する。チェック欄は読み取り専用の表示。生HTMLや数式の専用レンダリング、コードの構文色分けは行わない。

保存済みのMarkdownと同期形式は変えず、表示時に共通rendererを適用する。

## 未完了回答と色付け

Responsesの未完了回答は、出力上限・提供元の制限・その他の未完了を分けて説明し、途中の本文を校正結果として採用しない。原稿への自動反映は行わない。

校正の色付けは変更のない前後を先に除外する。比較対象の合計が1,024文字を超える大きな書き換えは、変更ブロック単位で強調する。通常の小さな変更は文字単位で比較し、結合文字・絵文字の境界を保つ。これは表示処理だけで、原稿bytesやUndo履歴を変更しない。
