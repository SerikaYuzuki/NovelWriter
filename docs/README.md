# 文書の入口

| 必要な情報 | 文書 |
| --- | --- |
| 開発開始・XcodeBuildMCP | [README](../README.md) |
| 作業範囲・検証・完了 | [AGENTS](../AGENTS.md)。Claudeも同じガイドを使う |
| 現行実装・既知の差分・未完了 | [CODE_HEALTH](CODE_HEALTH.md) |
| 利用者判断 | [OWNER_DECISIONS](OWNER_DECISIONS.md)。採択済み設計は[DECISIONS](DECISIONS.md) |
| 責務・依存・EditorKit | [DESIGN](DESIGN.md) |
| 見た目・操作 | [STYLE](STYLE.md)、[macOS toolbar](TOOLBAR.md)、[iOS](IOS.md) |
| コピー・AI | [原稿コピー](CLIPBOARD_AI_ASSIST.md)、[AI支援](WRITING_ASSISTANT.md)、[原稿保全・AI反映記録](PROTECTION_AI_ACCEPTANCE.md) |
| package・原稿出力 | [互換契約](CROSS_PLATFORM.md)、[EXPORT](EXPORT.md) |
| 保存・同期 | [概要](SNAPSHOT_SYNC_V2.md)、変更対象の[wire/schema/fixture](sync/v2/README.md) |
| 認証 | [AUTH](AUTH.md)、[Auth v1契約](auth/v1/README.md) |
| server・DB更新 | [実行手順](../SyncServerV2/README.md)、[権限・更新契約](sync/v2/deployment.md) |
| 通信入口 | [公開Tunnel](SNAPSHOT_SYNC_V2_TUNNEL.md)、[LANのTLS](SNAPSHOT_SYNC_V2_STAGING.md) |
| 削除・backup復旧 | [自宅サーバー運用](ACCOUNT_RETENTION_OPERATIONS.md) |
| ZimaOSアプリ・管理画面 | [生成・移行・切戻し・更新](ZIMAOS_APP.md) |
| 一般公開の条件 | [公開受入](COMMERCIALIZATION_IMPLEMENTATION.md) |

各文書はその責務の現行ルールを持つ。入口へ全仕様を転載せず、変更対象から必要な資料へ進む。実装との差はCODE_HEALTH、利用者の判断待ちはOWNER_DECISIONSへ集約する。運用記録には確認時点を明記し、現在の稼働状況と混同しない。

過去の実装・設計・テスト結果はGit履歴で参照する。Auth v1、SQL migration、現行schema/fixtureは互換性のため維持する。

文書構成は[OpenAIの記事](https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra)を参考に、常時読む指示を短くし、作業に必要な詳細へ進める形にする。製品固有の安全・互換契約は各仕様に残す。
