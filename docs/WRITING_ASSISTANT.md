# 明示送信のAI支援（D-089）

2026-09-12の利用者依頼に基づく新規実装。旧provider研究コードは再利用せず、通常版のmacOS下部パネルとiOSの適応inspectorから現在の1話を送信する。

## 操作と設定

- toolbar「AI支援」で開閉。macOSはAI支援メニューとCmd+Jも使用できる。macOSではプロットカードの右パネルと干渉しないよう画面下部に表示し、上の境界をドラッグして高さを調整できる。閉じると本文領域が元に戻る。
- 校正／感想／アドバイスを選び、「本文を確認して送信…」で現在の話のタイトルと本文を固定する。送信先と全文を確認し「この本文を送信」で1回送信する。
- API URLはHTTPSの完全なChat Completions endpoint。初期URLはOpenAI。モデルは利用者が入力し、用途別プロンプトも変更できる。
- 設定は端末内UserDefaults、キーはendpoint別のKeychain（端末限定・クラウド同期なし）。キーをUserDefaults、作品、同期DB、ログへ保存しない。
- 回答はpanel内の一時表示とテキスト選択。作品／話切替やpanelを閉じると取消・破棄する。原稿の自動置換、回答のDB保存、自動再送は行わない。

## 実装境界

`NovelApp/WritingAssistant/`を両app targetで共有する。`AssistantManuscript`はtitle/contentだけで、本文の取得は各platformのEditorKit committed captureから行う。IME中は拒否し、送信待ちで編集やローカル保存を止めない。preview後の編集は固定済みpayloadを変えず、別の話へ移動した場合はpreviewも失効する。

選択外の章・作品、人物、伏線、メモ、資料、内部IDを暗黙に追加しない。上限はtitle/contentの合計25万文字・UTF-8 1MB。本文をJSON文字列として囲い、本文中の指示へ従わないsystem instructionを添える。キーはpreview時ではなく明示送信時に読む。

HTTPはephemeral URLSession、cookie/cacheなし、redirect拒否、timeout付き。Chat Completionsの`model/messages/stream:false/store:false`を送り、`choices[0].message.content`を表示する。HTTP errorのbodyを画面やログへ転記しない。`store:false`は他社サービスの保存・学習方針の保証ではない。利用料金と保存方針は送信先サービスに従う。

[OpenAI公式Chat Completions仕様](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)を2026-09-12に確認。Responses API専用のendpointとは互換ではない。旧Experimental target、Codex subprocess、provider SDKは復活させない。clipboard支援は独立して維持する。

## 検証

APIの実送信には利用者自身の設定が必要。開発検証で私的原稿や実APIキーを送らない。Test compositionはKeychainの読取／保存／削除と実HTTPを拒否する。payload exact保持、範囲外dataなし、endpoint制約、空・過大本文拒否、response parsingを合成データで検証する。UIの実機受入と実サービス接続は別途記録する。
