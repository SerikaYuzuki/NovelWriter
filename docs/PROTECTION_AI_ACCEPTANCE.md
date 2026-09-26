# 原稿保全・AI拡張の反映記録（2026-09-26）

[合意](PROTECTION_AI_PLAN.md)をもとに、原稿保全、独立したAI記録同期、会話と範囲付き直接編集、MacのMCPを実装した。一般公開やWindows対応を今回の完了条件に加えない。

## 実装

- 同期作品は削除後1暦年保管し、元の作品を上書きせず新WorkID・DocumentIDで復元する。受領後7日までは各時点、その後は日本時間の日ごとの最後の復元点を表示する。account削除確定は作品保管より優先する。
- 本文のローカル保存を待たせず送信を再試行し、最古の未受領変更が5分残れば小さく表示する。他端末で削除された作品の端末原稿は、新しい未同期作品へ救出できる。可読ZIPと起動不能時のSQLite救出も実装した。
- アドバイスを会話にし、会話・共通と作品別の指示・依頼結果・編集記録を本文と別のSQLite／server laneへ保存する。指示の競合候補を残し、送信時の実効指示を記録する。
- プロット・人物・設定・章や話・本文・添付を依頼の範囲内で直接編集する。同じ対象の競合やsession/accountの変化は反映を拒否し、無関係な変更を維持する。変換中は最大15秒だけ待機。標準Undoと依頼単位の永続Undoを使う。
- MCPはMac起動中のloopback接続、初回登録したクライアントを信頼する方式。別作品・範囲外・ID変更を拒否する。再送は元依頼を照合して保存済み結果を返し、未完了処理を自動適用しない。

## 検証結果：成功

- `Scripts/check.sh`の最終全体実行が成功。canonical契約、依存／保存／通信境界、SwiftFormat、SwiftLint、Swift package、iOS compile、Mac 175件、iOS EditorKit 78件、iOS app 137件。
- 追加のSwift→Rust試験で、実際に生成したAI記録をserverと同じRFC3339／canonical parserへ渡した。日時・添付CRUDと順序・Undo、再送、履歴の参照ID付け替え、claim非継承、再起動したコピー再試行、コピー失敗時の本文成功を確認した。
- 使い捨てPostgreSQLで保全・復元・AIの追記／指示競合／scope・account消去を確認。AI追加分の統合2件とaccount消去1件が成功。実利用者データの削除試験はしていない。
- Opus 5.5が実装をレビューし、4件を修正後の再レビューはPASS。[初回指摘](reviews/2026-09-26-protection-ai-opus-implementation.md)、[再レビュー](reviews/2026-09-26-protection-ai-opus-fixes.md)。その後に見つかった、受信適用待ちの作品を再度開くとworkerが競合して反映を妨げる問題を修正し、関連7件と全体試験が成功した。
- Macの隔離したTest compositionで会話開始・編集範囲選択・共通／作品別指示の画面を確認した。実API／実Keychainを使わず、私的原稿を送信していない。
- 通常ReleaseのMac／iOS署名付きbuildが成功。Test構成ではコンパイルしないMCP起動部も通常Releaseで確認した。

## 稼働反映

自宅サーバーは`releases/protection-ai-20260926/`に記録を保存した。実装imageは`sha256:f07038268fe26a9ff063bb23042448c1d8b8a46c9b62b4bf42a6d91747943901`、schemaは0009。

切替前の暗号化backupを別DBへ復元し、所有者・権限を維持したschema 8→9更新とruntime role契約を確認した。本番も書込みを一時停止してmigrationを実行し、作品・snapshot・objectの件数を維持した。secret mountと環境設定は同一。mount列挙順が変わったため、順序に依存しない完全一致で再確認した。

新containerのhealthと公開HTTPSのAuth capabilitiesは成功（Auth epoch 1／Sync epoch 2）。新AI endpointは認証なしで401。更新後backup `20260926T065800Z-b22171d9`の暗号化・認証検証が2026-09-26 06:58:02 UTCに成功した。旧imageはschema 0009を知らないため、そのまま戻さず前進修正または検証済み復旧手順を使う。

iPhone 15 Pro Maxへの更新インストールと起動は成功。Mac版は署名済み成果物と旧版backupを準備済みだが、画面ロックにより旧版の通常終了・差替え・新版起動確認は未完了。

## 残る実利用上の確認

実APIの応答・課金送信、登録済み外部AIとのMCP実利用、Mac／iPhone間のAI会話と指示の同期、実端末での長時間IME・Undoと通常回線での60秒受領実測は未実施。インストールと起動成功を、これらの受入完了とは扱わない。

原稿commit直後かつAIコピーintent保存前の異常終了、またはAI保存領域を開けない場合は、元作品側に残るAI履歴から別途救出する。中断した依頼を自動再送・再適用しない。サーバー全損と外部backup不要の採択方針は維持する。
