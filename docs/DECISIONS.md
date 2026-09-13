# 現在の設計決定

現行の制約をまとめる。IDはコードからの参照を保つために残す。置換済みの全文・実験・時系列は整理前commit `ce69434c1`以前のGit履歴にあり、現行の実装指示には使わない。

## 編集・保存・互換

| ID | 現在の決定 |
| --- | --- |
| D-001 / D-005 / D-006 | SwiftUI＋platform adapter、EditorKitが本文を所有。TextKit 2、IME中のモデル反映・plugin介入禁止、公開APIへtext viewを出さない |
| D-002 / D-003 / D-018 / D-036 | `.novelpkg`は明示Import / Exportの互換形式。通常保存の正本ではない。内部配置・format versionはNovelStorageと[互換契約](CROSS_PLATFORM.md) |
| D-004 / D-028 | Chapter→Episode、順序は配列だけ。本文・話メモはEpisodeへ置く |
| D-009 / D-010 | portable repositoryはURL＋async。アプリが作品選択を管理し、DocumentGroupを使わない |
| D-016 / D-017 / D-023 / D-026 | 通常保存・履歴はSQLite。作品を切り替える前に保存し、復元は現在の編集を保全してから行う |
| D-022 / D-027 / D-037 | 原稿出力は独立module。TXT / Markdown / EPUB 3。PDF未実装。代表データで性能を確認する。[出力](EXPORT.md) |
| D-030 / D-033 / D-034 / D-055 | 明示置換はEditor command。字下げと鉤括弧処理はIME確定を守る。傍点は`｜字《・》`。末尾余白は表示専用 |
| D-031 | あらすじはadditive metadata。企画という独立機能は置かない |
| D-038 | 製品名はふみにわ／FUMINIWA。packageと必要な既存設定の読取互換を維持する |
| D-039 / D-041 | Loading / Ready / Recovery、読込失敗を空作品に置換しない。IME確定→保存→install、WorkID/session/account/gateを完了時にも照合 |
| D-064 / D-080 | 前景編集・local durability・remote workerを分離。端末SQLiteを唯一の正本とし、Snapshot Sync v2だけを通常同期へ使う |
| D-084 | account transitionをowner付きで停止・保存・再計画する。古い非同期完了を別accountへ適用しない |
| D-091 | 明示同期は最新checkpointの送受信確認まで要求する。保存だけを同期完了と表示しない |
| D-092 | 明示的な作品削除は端末とremoteのデータを消去する。削除前の未保存編集を先に保存し、失敗時は保持する |
| D-093 | 初回同期は検証済み履歴の最新checkpointを公開し、古い履歴の途中をheadにしない |

## 画面・AI

| ID | 現在の決定 |
| --- | --- |
| D-019〜D-021 / D-024 / D-029 / D-032 / D-035 / D-040 / D-044 / D-045 | 実装済み操作だけを表示する。[STYLE](STYLE.md)、[TOOLBAR](TOOLBAR.md)、[IOS](IOS.md)が現在の画面規約 |
| D-025 | 別名保存はCmd+Shift+S、明示snapshotはCmd+Option+S。保存先とscopeを明確にする |
| D-062 / D-066〜D-068 / D-070 | 作品選択から開始する。macOSはAIが右、プロットカードが本文下。プロット編集の右下に伏線。toolbarのカスタマイズ所有は一箇所 |
| D-089 | 校正は現在の1話、感想・アドバイスは選択した話を全文preview後に明示送信する。HTTP・キー・設定を本文保存から分離。[AI支援](WRITING_ASSISTANT.md) |
| D-094 | 原稿コピーは明示scopeのplain text。AI向け指示を付けない |

## 認証・運用・開発

| ID | 現在の決定 |
| --- | --- |
| D-007 / D-008 / D-013 / D-015 / D-056 / D-058 | macOS 14 / iOS 17、Swift 6、NovelKit。XcodeGenの`project.yml`がprojectの正本 |
| D-011 / D-014 | 直接配布を前提とし、検証はローカル。GitHub Actionsを導入しない。署名・公開の完了は別途確認する |
| D-012 | 縦書きは未対応 |
| D-042 | 通常の開発依頼は実装・品質改善。価格・法務・販促は明示依頼の範囲。必要なデプロイは対象・backup・反映後を確認して進める |
| D-076 | 責務別の構造、Swift 6境界、swift-testing。Swift sourceは400行で確認、600行で警告、800行超は分割する |
| D-078 | Auth v1はApple-only、opaque AccountID/session/Fence。内容保護はserverReadableV1、E2EEではない。[AUTH](AUTH.md) |
| D-081〜D-083 / D-085 | PostgreSQLの初期化・bootstrap・migration owner・runtimeを分離。runtimeにDDLを与えず、sequenceはUSAGEのみ。既存migrationと対象識別を保つ |
| D-086 | 検証なし／軽い／中ぐらい／重たいを影響で選ぶ。利用者の明示指定を優先し、マージだけでは段階を上げない |
| D-087 / D-096 | Apple以外の回復なし。明示削除予約から720時間、期限前の取消、猶予中の通常利用。remote消去のmarkerはatomic、削除完了はApple失効成功後。[自動運用](ACCOUNT_RETENTION_OPERATIONS.md) |
| D-088 | Windows 11、WinUI 3＋C#/.NET、MSI等のinstallerを計画。Windows実装は未完了 |
| D-095 | 添付250 MiB、8 MiB分割。自宅サーバーで再構成・digest確認。Cloudflare有料サービスを暗黙に追加しない |
| D-096 | 日次暗号化backupを作成から1暦年保持。2/29は翌年2/28。新backup成功後だけ期限切れを整理する |
| D-097 | 現行のコード・契約・運用に集約。廃止実装と過去資料はGit履歴へ移し、旧同期専用の検証を通常checkから外す。DB migration・現行Auth v1・互換fixture・原稿は保持する |

D-043、D-046〜D-054、D-057、D-059〜D-061、D-063、D-065、D-069、D-071〜D-075、D-077、D-079、D-090の旧provider・旧同期・置換作業は完了または廃止済み。必要な編集安全・local-first原則は上表の現行境界へ集約している。
