# 2026-09-13 全体レビューの実装修正

対象は[レビュー](PROJECT_REVIEW_20260913.md)のR2〜R14と関連改善。**R1は利用者指定で変更しない**。作業土台は`ea4d2e641`、ブランチは`codex/implement-review-except-r1-20260913`。未追跡の退避フォルダを保持し、push／PR／mergeは行わない。

## 実装

| 対象 | 変更 |
| --- | --- |
| R2 | iOSの削除対象をIDで固定。並べ替えは保存待ち前後の順序を照合し、session/account/gateを再検査 |
| R3 | upload本文読取前の認証とscope検査。同時読取2件・待機時間を制限 |
| R4 | provider認証時刻、遅延・同秒通知の検証待ち、永続retry。新規loginがidentity全audienceの古い確認を失効させる |
| R5 | Apple revokeは200だけ成功。4xxを含む他の応答は再試行状態を保持 |
| R6 | 削除待ちのfence更新を同一server/epoch/accountに限定。古い完了拒否、binding transitionの参照解放 |
| R7 | 作品参照がなくなったportable resourceを解放。共有参照があるbytesは保持 |
| R8・R9 | Inbox採用の非再帰探索、ObjectID単位の検証済みbytes共有 |
| R10 | 編集中作品の削除前にdirty revisionを保存。保存失敗時は原稿を保持して案内 |
| R11 | 明示snapshot・通常添付をsave coordinatorとdocument gateへ接続し、保存待ち中の入力もflush |
| R12 | RustをUnicode scalar上限に統一。Swift/Rust共通の文字数境界fixtureを追加 |
| R13 | 編集画面と作品一覧の認証失効を再ログイン案内へ反映。session/local scopeは保持 |
| R14 | 同期先利用不能・容量超過を区別して復旧を案内。恒久失敗を再起動後も保持 |
| 追加改善 | 明確なoffline分類、履歴reasonの日本語・時刻表示、AI未完了理由、校正色付けの計算量抑制、世代取得の軽量化、iOS Backの再検査 |
| 公開転送 | 8 MiB分割PUTを自宅サーバーで再構成。250 MiB契約とfinalize境界を維持 |

## 検証（重たい）

- 専用PostgreSQLでApple通知の重複、同秒順序、再起動後retry、別audience再ログイン、invalid credentialの一度限りの失効、revoke retryを確認。
- 旧版のrole-split構成から0006〜0007へ更新し、再実行・runtime権限・既存accountの保持を確認。
- 自宅サーバー上の隔離テストDBで250 MiB分割送信を完了。完全一致、途中の不可視性、重複再送、異なるbytes・別account・誤capability・gapの拒否、部分bytes解放を確認。
- Storeの削除・深いInbox・共有添付、Macのdirty削除と保存競合、iOSの保存待ち中ID固定、HTTP分割送信・404/413分類、Swift/Rust Unicode境界の対象テストを実施。
- 校正のRelease最適化合成測定：全面変更5,000文字は修正前約0.615秒、修正後約0.00046秒。実原稿・実アプリの操作遅延を測定した値ではない。
- 標準`Scripts/check.sh`は全項目成功。Mac App 170件、EditorKit iOS 78件、iOS App 137件を含む。実DBを使うHTTP分割送信の追加integration 2件も成功。

## 反映と受入

2026-09-13、自宅サーバーの稼働環境へ反映済み。実DB backupの復元・更新リハーサル後、API停止中に最新backupを取得してmigration 0006〜0007を適用した。作品・snapshot・account・session・object・receipt等の更新前後のfingerprintは一致。旧serverとbackupは保持した。新serverはhealthy、公開HTTPSのAuth capabilitiesは200・同じserver instance、未認証Syncは401を確認した。

反映imageは`sha256:7c1765c4cee6a8802f8388bfe84136c7d9902f21377be08b9698f63ee9c9cc89`。運用証跡は自宅サーバーの`/DATA/AppData/fuminiwa-sync-v2-role-split/releases/review-20260913/`に保管。署名済み実機受入、公開URL経由の認証済み250 MiB転送、Apple実通知の受入は未実施であり、一般公開完了とは扱わない。

Cloudflare管理画面で`serika.work`が無料プラン、最大upload100 MBであることを確認した。設定・契約プランを変更せず、処理・保存を自宅サーバー `192.168.11.5` に置く。

account削除30日・backup1年の公開運用、およびWindows W0はこの表のR2〜R14とは別の中期改善項目。完成を示す証拠はこの記録にまだない。
