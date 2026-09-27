# 結論：FIX_REQUIRED

**P1が1件**あり、AIデータの端末間同期がまったく動かない見込みです。他にP2が3件あります。コードは変更していません。レビュー中に`SyncV2Application+Writing.swift`が外部で書き換えられました（`finishWritingEdit`がoutcome recordを追記する形に変更）。行番号は読んだ時点のものです。

## P1 — 今回修正必須

### 1. AI recordの`createdAt`にタイムゾーンが付かず、serverが全recordを拒否する可能性が高い
- **場所**: `NovelKit/Sources/NovelWritingSupport/WritingRecords.swift:17-18`（生成）、`SyncServerV2/src/assistant_records.rs:22`（検証）、`NovelKit/Sources/NovelSyncV2Application/SyncV2Application+Writing.swift:74-80`（送信処理）
- **原因**: 日時の書式指定が年月日・時刻だけで、タイムゾーン部分がありません。この指定方法ではFoundationは「Z」などを付けず、`2026-09-26T03:04:05.123`のような形で出力するはずです。serverの`DateTime::parse_from_rfc3339`はタイムゾーン必須なので、SchemaViolationで拒否されます。
- **シナリオ**: Macで会話やプロンプトを保存し、同期を試みます。最初の未送信recordが4xxで失敗し、送信処理が中断します。同じnamespaceは送信の後に受信するため、受信にも進みません。結果として会話・共通プロンプトは同期されず、「同期は接続できると再試行します」が出たままになります。端末内の記録は失われません。
- **テストで検出されない理由**: Rustのテストは`"…Z"`を直書きしています（`integration_gate.rs:1017`、`account_deletion_gate.rs:35`）。Swift側には書式を確認するテストがありません。
- **修正案**:
  - `.timeZone(separator: .omitted)`を追加するか、`Date.ISO8601FormatStyle(includingFractionalSeconds: true)`を使います。
  - Swiftで生成した`createdAt`をRustのparserに通すfixtureテストを1本追加します。
  - 永続的に拒否されたrecord 1件がそのnamespaceの受信まで止めないよう、送信と受信の失敗を分けることも推奨します。
- **確認方法**: 出力を1行確かめれば確定できます。

## P2

### 2. AI履歴のコピー失敗が、確定済みの原稿操作を「失敗」として返す（今回修正必須）
- **場所**: `SyncV2Application+Conflict.swift:24`、`SyncV2Application+AccountClone.swift:14`、`:32`
- **シナリオ**: 両方残す（keepBoth）・救出・明示的なアカウント複製は、原稿側の処理がcommitされた後に`copyWritingHistory`を`try`で呼んでいます。`writing-assistant.sqlite`が破損・ディスク満杯・recordの読取失敗などでエラーになると、次のことが起きます。
  - keepBothは`recordOpened`と状態更新をせずに例外を返します。
  - 明示複製は`scheduleWorker`に到達せず、画面は失敗と表示します。利用者が再実行すると、新しいIDで2つ目の作品が作られます。
- **問題点**: 「AIの保存失敗が原稿の操作を失敗させない」という境界に反します。
- **修正案**: コピーは`try?`とログにとどめるか、原稿操作の成功後に独立して再試行する形にします。

### 3. IMEで変換中だと、無関係な範囲へのAI編集も一律に却下され、再適用の手段がない（受入前に修正推奨）
- **場所**: `AppState+WritingAssistant.swift:51-52`（67行・73行から呼ばれる）、`IOSDocumentStore+WritingAssistant.swift:54-55`、`AssistantChatView.swift:239-242`
- **シナリオ**: 「プロット」や「登場人物」の範囲で依頼を送り、回答を待つ間も本文を日本語入力し続けます。回答が変換中に届くと、captureの段階で`composing`になり、依頼は「反映しませんでした」で終わります。チャットには回答から再適用する操作がありません。
- **問題点**: 採択済みの「無関係な箇所の編集だけで一律に失効させない」とIMEの受入項目に反します。日本語入力では常時発生し得ます。
- **修正案**: 次のどちらかです。
  - 変換が確定するまで、時間上限つきで待ってから再度captureする。
  - 開いている本文を変更しない編集は、本文のcaptureなしで適用する。

### 4. MCPで同じrequestIdを再送すると、処理済みでも必ずエラーが返る（修正推奨）
- **場所**: `WritingMCPProtocol.swift:56`、`WritingSQLiteStore.swift:81-82`、`WritingMCPConnection.swift:24-27`
- **シナリオ**:
  1. `edit_work`が反映されますが、保存待ちやgate待ちで接続の30秒固定timeoutを超え、応答が失われます。
  2. toolの説明にある「再送時も同じID」に従って再送します。
  3. `WritingRecord`は呼出しごとに`createdAt`が新しくなるため、appendのbyte比較に失敗し、「AIの記録を読み取れませんでした」が返ります。
  4. 外部AIが「失敗した」と利用者に伝えます。
- **二重適用はしない**: content/before照合で拒否されることを確認しました。
- **修正案**: append前にjournal（`edit(id:)`）を参照し、`applied`なら成功、`prepared`/`rejected`ならその状態を返します。edit recordの同一性は`createdAt`を除いて比較します。

## 問題なしと判断した点
- **server**:
  - アカウント単位の`FOR UPDATE`で採番が直列化され、cursorが取りこぼしません。
  - 削除時は保管とtombstoneを残し、期限後purgeの順序も正しいです。
  - account削除と作品purgeの対象に新しい2 tableが入っています。
  - 復元はreceiptで冪等になり、AI recordは決定的なIDで一貫して付け替えられます。
  - runtimeの権限・sequence・identity在庫も揃っています。
- **アカウント漏れ**: 作品recordは、作品がactive accountにbindされ受領済みの場合だけ送ります。共通recordはaccountごとのnamespaceです。
- **遅い完了**: session/account tokenとkernel contextを再照合し、作品切替時にtaskをcancelします。
- **AI範囲**: grantの接頭辞判定、ID変更の禁止、並べ替えは同じ集合に限る点、appendOnly、添付の範囲確認を確認しました。
- **本文の3-way merge**: 同じ箇所の変更や曖昧な一致では適用しません。
- **Undo**: 逆操作を二重に実行しても、照合で拒否されます。
- **MCP**:
  - 採択済みの信頼方式どおり、申告scopeを機械的に強制しています。
  - Host・Originの検査と、リクエストごとのbearer認証があります。
  - 登録解除時に処理中のtaskをcancelし、claim後に失効を検出します。

## 検証
- 今回の検証: 読取のみのコードレビュー（実行なし）。
- build・テスト・実機・稼働環境: 未実施。
- P1は、Swiftで生成したrecordを実serverへappendするテスト1本で確定・回帰防止できます。