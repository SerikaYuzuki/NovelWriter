# 感想・アドバイスの保存形式

2026-09-13、D-089の追加依頼。既存のSnapshot attachmentのbytesとfileNameを利用する。wire schemaやattachmentの競合・削除規則は変更しない。

- ファイル名: `fuminiwa-feedback-<UUID>.md`。UUIDは回答生成時に一度作り、再保存でも保持する。
- 先頭行: `<!-- fuminiwa-feedback-v1 <base64のJSON> -->`、空行の後に元の回答Markdownをそのまま置く。
- JSON: `version: 1`、`id`、`purpose`（感想／アドバイス）、`scopeTitle`、`createdAt`。日時はSwiftのJSONEncoder標準Date表現（2001-01-01 UTCからの秒）でencode/decodeする。
- 1件のMarkdown上限はUTF-8 8 MB、読み込み全体上限は8.1 MB。空本文・校正用途・不正なmetadata・ファイル名とUUIDの不一致は専用記録として扱わない。
- 有効な記録だけを「資料」から除外し、「感想・アドバイス」に新しい日時順で表示する。未対応versionや壊れた記録は通常の資料として残し、消さない。
- 通常attachmentと同じSQLite checkpoint、object hash、remote同期、履歴、明示package取り込み・書き出しを通る。旧clientは通常のMarkdown資料として扱える。packageとの二重正本は作らない。
- 削除は現行Snapshotからのattachment削除で、通常の同期対象となる。過去の履歴やbackupの物理消去を意味しない。
- HTTP層は保存先を持たずhost callbackへ返す。hostは取得時の作品session／accountを照合し、document operation gateとIME確定／local save境界を通す。回答保存で本文を置き換えない。

検証fixtureは`AssistantFeedbackTests`の合成Markdown、snapshot encode/decode・削除と、両appの再起動永続化テスト。実原稿・実APIキーはfixtureへ含めない。
