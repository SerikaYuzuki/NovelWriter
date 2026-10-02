# 初回取り込みの待ち時間：現状と改善課題

2026-10-01時点。実装の基準は `c1663e54e`（一時的な取得失敗の再試行・iOSの取得中表示）と `e28aa268c`（一括取得・取り込み時の重複検証削減）。この文書は現状と残件の記録であり、追加の実装や新しい同期契約の決定ではない。

## 利用者が困っていること

iPhoneの棚にある端末未取得の作品を開く際、取得エラーとなり、数十秒〜数分待つことがあった。修正後に利用者が作品を開けたことを確認したが、初回の待ち時間が長い問題は残った。利用者は、本文をもっと早く開けるようにする改善を希望している。現時点では実装を保留し、課題を記録する。

一時的な取得失敗の再試行で開けるようになったものの、当初の通信失敗の原因を一意に特定したわけではない。データ破損と断定しない。

## 現在の処理

1. `SyncV2Application.open(workID:)` は端末SQLiteの `openLocal` を先に試す。端末に作品がない場合にだけremote-onlyの取り込みへ進む。
2. `downloadRemoteOnly` がサーバーのheadを取得し、そのSnapshot IDへ固定して祖先を含む履歴全体を取得する。
3. D-101の読取専用 `/v2/works/{workId}/download` でmanifestと小さなobjectをまとめて取得する。objectは履歴全体で重複排除する。1ページは最大256件・通常2 MiB、256 KiBを超えるobjectは従来の個別GETで取得する。詳細な例外・上限・旧serverへのfallbackは[一括読取契約](sync/v2/download.md)に従う。
4. クライアントがdigest、WorkID、親の欠落、循環、参照範囲、objectサイズ等を検証し、履歴graphを組み立てる。
5. SQLiteへ `stageRemoteGraph` → `verifyInbox` → `adoptInbox` の順に取り込む。永続化したInboxはverifyとadoptで再検証する。adoptの同一transaction内では、検証済みの不変graphを挿入に使い、同じsnapshotの再decodeを省く。親・既存行の一致・作品anchor・scope・CASの検証は残している。
6. ローカル取り込みを完了してから作品を開き、編集画面へ渡す。

**現在は、最新の本文だけ準備できても先に編集画面を開かない。履歴全体の取得・検証・保存が初回表示の前提になっている。**

取り込み済みの作品はローカルから開くため、以下の約25秒が毎回の作品切替にかかるという意味ではない。通常のローカルopenの所要時間は今回の比較では測定していない。

## 測定結果と限界

対象は履歴1,467世代、重複排除後のobject 1,461個の1作品。manifestとobjectの合計は約19 MB。原稿本文・作品名・認証情報はこの文書やfixtureへ転記しない。

Mac上のReleaseビルドで、同じデータのコピーを使い、毎回空の隔離SQLiteへ取り込んだ。通信はURLProtocolによる模擬応答で、各リクエストに5 msの待ち時間を加えた。実サーバーの処理時間、実回線の帯域・遅延、iPhoneの性能は再現していない。UI描画までの測定でもなく、1作品・個別試行の比較であり、一般的な上限や平均値ではない。

| 比較対象 | リクエスト数 | 取得処理 | ローカルopenまでの合計 |
| --- | ---: | ---: | ---: |
| 改善前の個別取得・取り込み | 2,930 | 20.84秒 | 64.37秒 |
| 一括取得のみの中間版 | 13 | 4.70秒 | 48.45秒 |
| 一括取得＋重複検証削減 | 13 | 4.31秒 | 25.18秒 |

個別取得の2,930回には、比較用クライアントが旧server相当の404でfallbackする最初の1回を含む。新方式の13回にはhead取得を含む。

最終版の内訳：

| 処理 | 時間 |
| --- | ---: |
| 取得・graph構築 | 4.31秒 |
| stage（空storeの作成を含む） | 5.28秒 |
| verify | 6.77秒 |
| adopt | 8.79秒 |

残りはopen等の小さな処理。測定上は通信回数削減後も、ローカルでの履歴処理が約21秒を占める。**「64秒から25秒へ短縮」は改善の証拠だが、初回表示の速さとして解決済みとは扱わない。**

## 残る問題

- 最新本文の量より、累積した履歴の量に初回の待ち時間が左右される。
- 全履歴を取り込むまで本文を開けず、ページ化しても表示開始の条件は変わらない。
- stage・verify・adoptそれぞれに履歴全体の検証やSQLiteの読書きがある。同一transaction内の重複は削減したが、処理段階をまたぐ検証コストは残っている。
- 今回の測定はiPhoneでの初回表示時間を保証しない。履歴量・添付量・回線条件の異なる作品での測定も未実施。

## 次回の改善検討

目標は、初回に本文を開けるまでの待ち時間を短くすること。全履歴の取り込み完了時間と本文の表示・編集開始時間を分けて評価する。具体的な秒数の受入基準は未決定。

有力な検討候補は、最新snapshotの本文・必要なobjectの取り込みを先行し、過去の履歴を後から取得する方式。ただし、これは**未採用の設計案**であり、現行graphから祖先を省くだけでは実装できない。次の契約を先に整理する必要がある。

- 祖先未取得の作品をローカルに保持する状態と、現在の親存在・graph検証条件との整合。
- 履歴取得中の編集、自動保存、publish、競合判定・解決、永続Undoと復元が必要とするデータ。
- 未取得の履歴の表示、オンデマンド取得、オフライン時の利用可能範囲。
- 中断・再起動後の再開、重複取得、取得中のhead更新、account切替・削除・作品切替時の失効。
- 旧client/serverとの互換、schema変更の要否、必要なDecision・fixture・契約文書。

並行して、現行の全履歴取り込みを維持したままSQLite操作や検証処理をさらに減らせるか、段階別にプロファイルする余地がある。ただし、全履歴完了を表示の前提にする限り、履歴量による待ち時間は残る。

履歴を削除したり、件数上限で打ち切ったり、検証を省略して解決したことにはしない。編集・自動保存のローカル完結、IME・Undo、WorkID/session/account/世代とdocument operation gate、失敗時の原稿保持を維持する。

## 確認済みの範囲

既存実装の修正時には全体チェックと隔離PostgreSQL/HTTP結合テストが成功した。サーバーは暗号化バックアップ後に反映し、切替前後のデータ件数一致・正常稼働・認証必須を確認した。iPhoneへの更新インストールも成功した。

最終版のiPhone起動確認は端末ロックのためできていない。利用者が開けたと確認したのは先行する取得失敗修正版であり、最終版の初回取り込み25秒や速度改善を実機受入済みとはしない。対象作品はすでに取り込み済みのため、単なる再openでは初回取り込みの評価にならない。

この文書追加は説明のみの更新で、検証段階はD-086の「検証なし」。追加実装・テスト・build・デプロイは行わない。

## 実装を追う入口

- `NovelKit/Sources/NovelSyncV2Application/SyncV2Application+Library.swift`
- `NovelKit/Sources/NovelSyncV2Runtime/ProductionSyncV2RemoteClient+Catalog.swift`
- `NovelKit/Sources/NovelSyncV2Runtime/ProductionSyncV2RemoteClient+DownloadPages.swift`
- `NovelKit/Sources/NovelSyncV2Runtime/ProductionSyncV2RemoteClient+SnapshotGraph.swift`
- `NovelKit/Sources/NovelSyncV2Store/LocalSyncV2Store+Inbox.swift`
- `NovelKit/Sources/NovelSyncV2Store/LocalSyncV2Store+SQLite.swift`
- `NovelAppIOS/Library/IOSDocumentStore+LibraryV2.swift`
- `SyncServerV2/src/snapshot_download.rs`
- [D-101](DECISIONS.md#d-101-初回取り込みの一括読取2026-10-01)、[一括読取契約](sync/v2/download.md)
