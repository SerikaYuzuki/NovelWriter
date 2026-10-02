# サムネイル（D-104）

作品の表紙、人物、世界観ノート（WorldNote）だけに画像を設定する。本文・章・話・プロット等には追加しない。NovelCoreのCodableモデル、Snapshot Sync v2 wire、server、SQLite schema、`.novelpkg` v3の形式は変更しない。

## 保存と所有者

D-089と同じ予約名attachmentを用いる。名前は`fuminiwa-thumbnail-v1-{work|character|world-note}-<lowercase UUID>.jpg`。workは`NovelDocument.id`、characterは`CharacterID`、world-noteは`WorldNoteID`を使う。AttachmentIDがpackage取り込みで変わっても、名前で所有者へ結び付ける。

選んだ元画像は保存しない。向きを適用し、指定範囲を表紙2:3／人物・世界観1:1に切り抜き、sRGBの新しいbitmapへ再描画してJPEGだけを保存する。EXIF・GPS・XMP・IPTC・コメントは引き継がない。ImageIOが生成するEXIFも除去する。表紙の長辺は1024 px以下、それ以外は768 px以下、1枚200 KiB以下。JPEG品質を順に下げ、収まらなければ案内して変更を中止する。HEICの保存はしない。画像処理と予約名はNovelThumbnail、表示・選択・切り抜きはNovelUIが担当する。

設定・置換・削除はdocumentとattachmentを通常のcheckpointへまとめる明示操作。D-103に従って既存の添付編集と同様に昇格でき、network完了を保存の条件にしない。作品session／account／ownerを検査し、失敗時は以前の添付を保持する。人物・世界観の削除では、削除するownerとその画像を同じ変更として渡し、同一checkpointで保存する。画像削除は確認付きで、復旧は作品の履歴から行う。新しい永続Undoは設けない。

旧clientによるowner削除等で既に孤立している画像は自動削除しない。所有者が存在する予約画像だけを新clientの「資料」から隠し、孤立画像は通常資料として保持・表示する。未知version・不正な予約名も推測して削除しない。通常のファイル取り込みでは予約名に接頭辞を付け、サムネイル設定を迂回させない。

## 表示・外部アクセス

棚は現在のlocal snapshotから必要時に読み、表示寸法でdecodeした画像を容量制限付きのメモリcacheに置く。読取りによって作品を開いたり、local leafを昇格したり、remoteを取得したりしない。未取得作品と表紙未設定にはSTYLEの表紙placeholderを使う。画像bytesをSyncV2LibraryItemへ入れない。

予約名prefixの画像は孤立・未知versionを含めてアプリ内AIのチャット・校正・感想・送信payloadから除外する。MCPの`read_work`／`edit_work`でも予約名の作成・読取・置換・削除や既存IDの再利用を拒否する。添付全体の書き戻しでは除外した画像を再結合し、普通の資料編集で画像を失わない。MCPによるowner削除も同じowner削除規則を通る。原稿コピーはplain textのまま。

2026-10-03のD-104変更により、MCP専用の`read_thumbnail`／`set_thumbnail`／`remove_thumbnail`だけは、現在の作品に存在する3種のownerの画像を扱える。作品・session・account・指定範囲を検査し、手動設定と同じNovelThumbnail処理で保存する。保存形式・予約名・切り抜き形状・寸法・Snapshot Sync v2の保存契約は不変。

MCPの`undo_edit`は既存の端末内AI journalに保持した変更前後の縮小JPEGを使い、変更後と現在値が一致する場合だけ取り消す。同期する依頼記録は対象・digest・cropのみで画像を含めない。端末外へ復元したAI履歴からこのUndoは実行できず、画像自体の復旧には通常のSnapshot履歴を使う。手動の削除確認・履歴復旧の規則は上記のまま。[専用ツール・上限・Undoの詳細](../../WRITING_ASSISTANT.md#mcpのサムネイル)。

TXT／Markdown／EPUBおよび可読フォルダ出力にサムネイルを含めない。作品を持ち運ぶ明示`.novelpkg` Import / ExportとSnapshot履歴・同期では通常attachmentとして保持する。旧clientにはJPEGの通常資料として見えるが、形式変更やserver対応は不要。
