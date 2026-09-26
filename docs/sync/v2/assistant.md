# Snapshot Sync v2: AI records

AIの会話・プロンプト・依頼結果は本文snapshotと別の追記専用laneへ保存する。本文の復元やlocal/server選択でAI記録を巻き戻さない。APIキー、MCP資格情報、送信先、モデル設定はこのlaneへ含めない。

## Wire / 認可

`GET /v2/assistant/records?workId=<UUID>&after=<sequence>`と`POST /v2/assistant/records`。既存v2認証header・account fence・server instanceを使用する。workId省略はaccount共通promptのみ。作品指定はそのaccountに属する非削除のbound workに限る。未送信作品、parked workは端末だけに保存し、受領済みheadのある作品から同期する。

[record schema](assistant-record.schema.json)、[SQL](assistant-records.sql)、[canonical fixture](fixtures/canonical/assistant-record.json)が追加契約。POSTはJSONで2 MiB上限、payloadはJSON objectを文字列化したもの（通常1,000,000 UTF-8 bytes上限）。createdAtはRFC3339を検証して表記を保持する。サーバーのsequenceが受領順、createdAtは端末の表示用日時である。

応答は`{record,sequence,conflicted}`。同じID・同じ内容は同じ結果を返し、違う内容での再利用は拒否する。scope row lockの下で処理する。GETはsequence昇順で最大8件、続きがあれば`nextAfter`を返す。共通laneと作品laneそれぞれにaccount/fence別cursorを保持する。ページの順序・account・work・acknowledgement内容をクライアントも照合する。

promptのkeyは用途、parentIdは変更前の採用版。現在の採用版とparentが違う投稿は削除せずconflictedとして保管し、採用版を上書きしない。競合画面で案を読み込み、現在の採用版をparentとして再保存できる。messageは一意IDで追記する。requestは開始・最終結果を別レコードとして記録し、当時の実効プロンプトを開始記録へ残す。

## 端末とAI実行

端末の`writing-assistant.sqlite`は本文DBとは別のWAL。記録・outbox・cursor・依頼単位のUndo journalを保持する。AI保存領域を開けなくても本文保存を起動できるが、AI操作はエラーを表示する。移行時は端末の用途別プロンプトを初期revisionとして保存し、既存server設定と重なる場合は競合案として残す。

前面で開いている作品のAI laneを約10秒ごとに再試行する。本文のcheckpointから待たない。アカウントや作品の変化をawait前後で照合する。同期は再送可能な記録だけを扱い、AI提供元への依頼や原稿への適用は自動再送しない。

会話開始時に作品全体の参照を許可する。送信ごとに編集範囲を選び、既定値は相談のみ。話への追記と既存本文編集を分け、送信後は相談の設定へ戻す。最新の共通指示＋作品別指示を使い、会話直近30発言を送信する。元の会話は削除しない。作品が大きい場合は選択中の話・構成・設定を送り、他の話の本文を省略する。送信内容全体が上限を超えると送信しない。

編集はUUIDで指定するモデルの項目／フィールドを対象にする。権限外、同じ対象の変更、作品・session・accountの不一致を拒否する。IME中は最大15秒だけ確定を待ち、再取得時もscopeとcancelを照合する。本文は変更区間の前後32文字を使って無関係な同時編集を保持し、一意に対応づけられない場合は反映しない。配列の並べ替えはIDと順序を比較し、同時の内容修正を保持する。作品自体やIDの書換えは公開しない。

適用前に元依頼とUndo用の補足情報を分けて永続claimへ記録し、同じ依頼IDは再適用しない。MCPの再送は元依頼が一致すればapplied/prepared/rejected/undoneを返す。checkpoint完了後に適用結果を記録する。途中終了のprepared journalを自動実行せず、明示Undoでは現在値が変更後と一致／安全に対応づけられる場合だけ逆変更する。現在の本文はEditorKitのnative Undoを1単位使い、話の切替後・構造化データは永続journalの取り消しを使う。

## MCP

Macアプリ起動中だけ、`127.0.0.1`へStreamable HTTP `/mcp`を公開する。登録クライアントごとのランダム資格情報を端末限定Keychainへ置き、アプリには照合用digestを保存する。初回登録は利用者の明示操作。登録後は外部AIが指定範囲を申告することを信頼し、アプリがその範囲を機械的に制限する。外部AIによる自然言語指示の解釈は検証できないという採択済み境界を維持する。

`read_work` / `edit_work` / `undo_edit`。常に現在のworkとsessionを照合し、本文・章・話・人物・プロット・伏線・メモ・設定ノート・添付資料を扱う。添付の編集は1件300 KB以内、base64付き値を照合する。大きな添付は従来の資料画面で扱う。作品削除、account、APIキー、設定、任意ファイル、shellは公開しない。

Host・Origin・Bearerを検証し、loopback以外へbindしない。HTTP header 16 KiB、body 2 MB、30秒、同時接続16件。GET/SSEは使わず405、通知は202。MCPの2025-03-26 / 2025-06-18 / 2025-11-25を受け付ける。解除は待機中の処理も取消し、適用前のcancel確認で止める。

## 保管・復元・削除

作品の1年保管にAIレコードも含め、期限後purgeで削除する。account消去は共通・作品AIレコードと復元receiptも同一transactionで消去する。日次DB backupへ含まれる。

サーバーの別作品復元は本文の選択snapshotとAIの取得時刻を別に記録し、AI ID・会話の参照を新IDへ付け替える。元の記録を残し、依頼はhistoricalにする。端末の別作品救出・account clone・keep-bothもAI記録を複製するが、実行中の権限や適用claimは複製しない。復元した会話の参照許可は新作品で取り直す。本文の複製成功をAI履歴コピー失敗で失敗に変えず、独立した永続intentを再試行し、transaction内のreceiptで重複を防ぐ。本文確定直後かつintent保存前の異常終了、またはAI保存領域そのものを開けない場合は、元作品側のAI履歴から別途救出する。

復元operation receiptは元work・snapshot・新work/documentを一緒に束縛する。完了済みの同一操作は元の保管期限後も同じ結果を返す。新しい期限後復元は拒否する。receiptは本文を含まない。

アプリ起動不能時の`export-local-recovery.py`は本文DBとAI DBをそれぞれread-only backupで読み、可読会話・プロンプトと原レコード・Undo journalを出力する。二つのDBの取得時点は同一transactionとはみなさない。
