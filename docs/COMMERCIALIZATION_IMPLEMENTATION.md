# 商業化基盤 実装状況

**基準日: 2026-08-09 / 状態: 実装面の公開準備中（公開用ビルド品質は未完了）**

本書は[商業化総合監査](COMMERCIALIZATION_AUDIT_2026-07-19.md)のうち、アプリの実装・機能・UI/UX・データ安全・性能・アクセシビリティ・互換性・ビルド／配布技術だけを実装へ落とす進捗表である(D-042)。価格、法務、販促、決済、事業運用は、明示依頼がない限り本書のGateやバックログに含めない。設計の正は[DESIGN.md](DESIGN.md)、個別判断は[DECISIONS.md](DECISIONS.md)を優先する。

## 今回までに実装した範囲

| Gate | 現在の結果 | 境界 |
| --- | --- | --- |
| Brand | 日本語名「ふみにわ」、配布名`FUMINIWA`、bundle ID、Document Type / UTTypeを移行 | `.novelpkg` v1〜v3、NovelKit系名称、legacy toolbar IDは互換資産として維持 |
| Preference migration | 旧bundle domainからrecent URL、section、Editor設定をallowlistで一度だけ移行 | 新値を上書きせず、旧domainと旧作品を削除・一括移動しない |
| Safe Launch | `loading` / `ready` / `recovery`を分離。読込失敗時は原稿もrecent URLも変更しない | Recoveryは再試行、Finder表示、別作品選択、明示的新規作成を提供 |
| Lifecycle safety | 同時bootstrapを共有Taskへ合流。作品切替・別名保存・資料・snapshotをFIFO化し、古い確認操作をsessionで拒否。切替前にフォーム／IMEを旧作品へ確定してWorkbench変更を止め、終了要求後の作品操作を遮断 | 外部rename／削除、同期・別プロセス競合の検出は後続Gate。待機TaskのcancellationとSave As確定失敗時に残るcopyの案内／cleanupはP2 follow-up |
| Payload integrity | manifest参照の話本文、world参照本文を必須valid UTF-8としてfail-closed。存在するメモもvalid UTF-8を要求 | 空メモのファイル省略は互換仕様として維持。完全なpackage validatorではない |
| Product truth | 実処理のないprovider panel、AI状態、`Cmd+J`を出荷UIから撤去。通常版には実在する非通信操作としてclipboard prompt copyだけを表示 | 「校正用／アドバイス用プロンプトをコピー」と正確に表現し、AI実行、送信、応答、Applyがあるように見せない |
| Clipboard AI支援 | 校正／アドバイス×本文選択／話／章のplain text promptを明示操作でsystem clipboardへコピー | provider／network／key／process／`NovelAI`依存なし。clipboardは他アプリ、manager、Universal Clipboardから読まれ得る共有境界で、履歴非保持やsecure eraseを保証しない |
| AI technical contract | EditorKitの選択transactionと通常版のclipboard promptだけを現行面として保持。旧Experimental provider／sidecar実装はD-075で削除 | provider再開時は旧APIを流用せず、最新stable SDK／APIを新Decisionの下で再評価する。通常版のprovider／network／key／実原稿送信は0件。`.novelpkg`は変更しない |
| Native UX | chromeはシステムLight／Darkへ追従。本文キャンバスは独立した利用者設定で既定暗色 | 下部は保存状態、再試行、話／全体文字数、検索不一致だけを示す |
| Explicit save | Fileメニューの`Cmd+S`を`AppState.saveNow()`へ接続。iCloud結線済みなら続けて明示同期(D-073) | `ready`な作品だけを自動保存・終了前保存と同じrevision直列化で端末へ保存し、結線済みだけiCloudへ送る |
| Build baseline | Hardened Runtimeをproject設定で有効化 | Developer ID署名・公証済み配布物、別Mac検証の完了を意味しない |

## Experimental provider研究履歴（実装削除済み）

[AI_INTEGRATION.md](AI_INTEGRATION.md)とD-043 / D-046〜D-053はAIを出荷した記録ではなく、B4-Dまでの研究成果と将来再開時の安全契約である。D-075でprovider／fake UI／sidecarの実装・fixture・testを削除し、実provider、B4-E以降、network、credential、実原稿送信は最新stable SDK／APIの明示再評価まで延期した。実装結果と未達Gateは[Codex SDK feasibility実装レポート](CODEX_SDK_FEASIBILITY_REPORT_2026-08-09.md)を正とする。

通常版の現行AI支援は[clipboard prompt契約](CLIPBOARD_AI_ASSIST.md)だけであり、旧Experimental基盤、provider、Node／CLI／sidecar、network、Keychain、process supervisorへ依存しない。Package Validator GateとExternal Change / Conflict Gateは引き続き公開Release作業として優先する。

現行AI実装で完成扱いにできる範囲は上表のEditorKit選択transactionとclipboard promptだけである。以下のprovider／sidecar詳細はD-075前の研究履歴であり、実装・出荷・再利用契約ではない。

B3の`candidateRootDigest`、root内のself manifest、packager自身が再計算したdigest、B4-Aのproposal、B4-B／B4-C observation、observed runtime／local probeはいずれもproduction approvalではない。production catalogは意図的に空で、承認済みcandidate／Node／SDK／CLIと実行経路は0件である。packaging失敗後のpartial rootは手動で隔離・削除し、B4-C observationをauthority／capabilityへ昇格させず、B4-D abstract channelをactual processへ結合しない。Node version、完全なloaded artifact inventory、immutable verify-to-use、same-user swap、anti-rollback、OS containmentは未達であり、B4-E以降を実装せず延期した。これはCodex／OpenRouterが利用可能または公開可能という意味ではない。

B4-A inventoryは、B3全copy集合であるdeployment candidateと、`evaluatedSource`／`resolutionMetadata`／`executable`／`conditional`／`provenance`／`requestData`／`operatingSystemTrust`／`forbidden`のroleを分離する。content identityも`exactFile`／`boundedRequestData`／`operatingSystemProvided`／`forbidden`を区別する。provenanceを実評価sourceと数えず、request dataをartifact identityへ混ぜず、OS trustを暗黙の無制限allowlistにしない。

domainで実装済みのhard guardは、app-provided inputとraw structured output、stream delta、decoded resultの文字数／UTF-8 byte数、注意点20件上限、wall-clock timeout、result usageの検証である。細切れdeltaはdomainでboundedに集約してUI更新数を抑える。providerはstreaming／cancellation／usage reportingを必須とし、`outputTokens`は必須かつ非負、`inputTokens`は省略可能だが存在時は非負としてfail-closedにする。ただしusageは事後報告であり費用capそのものではない。実providerの`maximumOutputTokens`相当parameter、実送信直前payload capture、wire event byte／件数、process resource limitはadapter Gateであり、現在は未実装である。

2026-08-09の調査baselineはTypeScript SDK `0.147.0`である。合成captureではliteral U+2028／U+2029を含む同じCLI出力がNode 22.23.1ではround-tripし、Node 26.4.0ではSDK内部で分断される差、生stderr／errorがSDK例外へ入り、Abortがdirect childへのsignalに留まることを確認した。これらは日付固定の互換性証拠であって将来の採用値ではない。再開時は最新stable SDK／API、Node／native境界、tool、session保持、output cap、cancel、artifact、OS隔離をゼロから再評価し、旧0.147.0のversion／path／hashを流用しない。

provider／service側の保持期間と学習利用、SDK／CLI local artifact、料金単位とrequest上限の一次資料根拠は未検証のまま延期している。通常版clipboard支援はprovider情報を表示せず、system clipboardへ出た後の保持、同期、外部AI利用を保証しない。

OpenRouterを含む実adapterは現行backlogに置かない。将来再開する場合もCodexと別adapter／別PRとし、自動fallbackを行わず、新しいexact previewと明示確認を必要とする安全契約は維持する。

## 次の一単位: Package Validator Gate

次はpackageを開く前、保存物を置換する前、修復コピーを採用する前に共通利用できる検証境界を作る。

1. 全domainのduplicate ID、参照先欠損、IDファイル名の不一致を型付きエラーにする
2. package rootと既知pathの各componentでsymlinkを拒否し、package外を読み書きしない
3. 深さ、ファイル数、JSON／本文／添付／総byte数にresource budgetを設ける
4. manifestから参照されない本文・メモ・世界観本文を消さずにinventory化し、隔離または修復コピーへ保全する
5. 元packageを直接修復せず、検証済みの別コピーを作って差分と採用判断を利用者へ示す
6. 一時packageを置換前に検証し、失敗時は既存packageとdirty状態を維持する
7. schemaとgolden / failure fixtureへ統合し、[CROSS_PLATFORM.md](CROSS_PLATFORM.md)のW0残件を同じ契約で前進させる。このGateだけでW0完了とはしない

## 続く一単位: External Change / Conflict Gate

Finderでの移動／削除、同期サービス、別プロセスによる変更を検出し、黙って旧URLへ別作品を再作成したり外部更新を上書きしたりしない。現在作品と外部状態を比較し、状況に応じて再読込、別名保存、競合コピーの保全を利用者が選べるようにする。

## 実装面で残る主要Gate

- AppIcon、ロゴ、Finder / Dock / About / DMGを含むブランド視覚品質
- Developer ID署名、公証、stapling、Hardened Runtime、クリーンな別Mac／新規ユーザーでのGatekeeper検証
- 更新機構、versioning、release note、rollback、旧版との文書互換検証
- インストール、初回起動、既存利用者移行、Recovery、アンインストール／データ保持の説明
- アクセシビリティ、キーボード、VoiceOver、Light／Dark、Reduce Transparency、長文／大量データの実機QA
- アプリ内のバックアップ／復旧手順、診断情報、失敗時の救出導線

これらを通るまでは「実装面の公開準備完了」「原稿を失わない」「Windows互換完了」「AI対応」と表現しない。
