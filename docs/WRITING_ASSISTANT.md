# 明示送信のAI支援（D-089）

2026-09-12の利用者依頼に基づく新規実装。旧provider研究コードは再利用せず、通常版のmacOS右パネルとiOSの適応inspectorから現在の話・指定した話・章全体を選んで送信する。

## 操作と設定

- toolbar「AI支援」で開閉。macOSはAI支援メニューとCmd+Jも使用できる。macOSでは右側にAI、本文下部に横並びのプロットカードを表示する。閉じると本文領域が元に戻る。
- 「送る範囲」で現在の話・指定した話・章全体を選ぶ。校正／感想／アドバイスを選び、「本文を確認して送信…」で対象のタイトルと本文を固定する。送信先と全文を確認し「この本文を送信」で1回送信する。
- 章全体は章内の配列順で各話の見出しと本文を含む。編集中の話が対象内なら確定済みの最新本文を取得し、IME中は拒否する。その他の話は現在のローカルdocumentから取得する。
- macOSの自動校正反映は「現在の話」だけに限定する。指定した話・章全体は回答表示のみ。範囲変更・章や話の構成変更でもpreviewと実行中の要求を失効させる。
- API URLはHTTPSのResponsesまたはChat Completions endpoint。初期URLはOpenAI。モデルは用途別に設定し、OpenAIの `/v1/models` の利用可能一覧を新しい順で選べる。用途別プロンプトも変更できる。
- 設定は端末内UserDefaults、キーはendpoint別のKeychain（端末限定・クラウド同期なし）。キーをUserDefaults、作品、同期DB、ログへ保存しない。
- 回答はpanel内の一時表示とテキスト選択。作品／話切替やpanelを閉じると取消・破棄する。macOS校正は送信時点と同じ本文・作品session・話・accountの場合のみ、JSONの全文をEditorKitのUndo可能な正規編集で反映する。IME中や本文変更後は拒否する。iOSは回答表示のみ。回答のDB保存、自動再送は行わない。

校正後の追加・変更文字は黄色で表示し、自動保存では消さず、明示保存のローカルcheckpoint成功後に消す。削除済み文字には色を付けられない。色はeditorの一時表示で、話切替・終了で破棄する。感想・アドバイスはMarkdown表示する。

## 実装境界

`NovelApp/WritingAssistant/`を両app targetで共有する。`AssistantManuscript`はtitle/contentだけで、対象内の編集中本文は各platformのEditorKit committed captureから取得する。その話がIME中なら拒否し、送信待ちで編集やローカル保存を止めない。preview後の編集は固定済みpayloadを変えず、別の話へ移動した場合はpreviewも失効する。

選択外の章・作品、人物、伏線、メモ、資料、内部IDを暗黙に追加しない。上限はtitle/contentの合計25万文字・UTF-8 1MB。本文をJSON文字列として囲い、本文中の指示へ従わないsystem instructionを添える。キーはpreview時ではなく明示送信時に読む。

HTTPはephemeral URLSession、cookie/cacheなし、redirect拒否、timeout付き。他社Chat Completions endpointでは`model/messages/stream:false/store:false`を送り、`choices[0].message.content`を表示する。HTTP errorのbodyを画面やログへ転記しない。`store:false`は他社サービスの保存・学習方針の保証ではない。利用料金と保存方針は送信先サービスに従う。

[OpenAI公式Chat Completions仕様](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)を2026-09-12に確認。OpenAIとResponses endpointは `instructions/input/store:false` を送り、完了したmessageのoutput_textだけを取り込む。旧Experimental target、Codex subprocess、provider SDKは復活させない。clipboard支援は独立して維持する。

## 検証

APIの実送信には利用者自身の設定が必要。開発検証で私的原稿や実APIキーを送らない。Test compositionはKeychainの読取／保存／削除と実HTTPを拒否する。payload exact保持、範囲外dataなし、endpoint制約、空・過大本文拒否、response parsingを合成データで検証する。UIの実機受入と実サービス接続は別途記録する。

### 今回のローカル確認（2026-09-12）

EditorKit 133テスト、AI通信境界・macOS表示11テスト、保存・遷移10テストが成功。macOS通常版とiOS Simulator build成功。SwiftLintは既存警告のみ。全体checkはPython/Swift conformance成功後、Rustのcargo不在で未完了。実API接続・実原稿への校正反映・署名済み実機受入は未実施。

仕様確認: [OpenAI Models一覧](https://developers.openai.com/api/reference/resources/models/methods/list)、[Responses移行ガイド](https://developers.openai.com/api/docs/guides/migrate-to-responses)。

2026-09-12追加修正: 校正は文章による形式指定に加え、`content`のみを必須とするstrict JSON SchemaをResponses/Chat Completionsへ送る。非対応モデル・途中出力は本文に適用しない。AIパネル開閉に0.22秒のアニメーションを追加し、Reduce Motionでは無効にする。

追加修正の検証: AI返答schema・アニメーション後のeditor保持・ローカル作品の反復保存と再起動を含む14テストが成功。ログインあり／なしで同じWorkID・作品数・本文の保存を確認した。実原稿と実APIへの上書き試験は未実施。
