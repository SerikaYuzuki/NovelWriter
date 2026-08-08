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
| Product truth | 実処理のないAI panel、AI状態、`Cmd+J`を出荷UIから撤去 | AIはprovider adapter、送信先／送信範囲、provider／serviceの保持期間と学習利用、local SDK／CLI artifactの場所・範囲・保持期間、料金単位とrequest上限の技術的な検証／表示、送信確認、取消、結果レビュー、失敗時挙動を実装してから任意機能として再検討 |
| AI technical contract | `NovelAI`、EditorKit transaction、App local context、送信前／適用前stale、one-shot、fake provider、exact preview／確認／cancel／diff／Copy／明示Applyの共通UI、Codex sidecar v1のNode／Swift mock protocolを実装。別target／bundle／保存rootの`FUMINIWAExperimental`だけに含め、通常版とのbuild graphを機械監査 | 実Codex／OpenRouter provider、SDK／CLI接続、Keychain、network、OS-level隔離、process lifecycle／artifact実証は未実装。`.novelpkg`は変更しない |
| Native UX | chromeはシステムLight／Darkへ追従。本文キャンバスは独立した利用者設定で既定暗色 | 下部は保存状態、再試行、話／全体文字数、検索不一致だけを示す |
| Explicit save | Fileメニューの`Cmd+S`を`AppState.saveNow()`へ接続 | `ready`な作品だけを自動保存・終了前保存と同じrevision直列化で保存 |
| Build baseline | Hardened Runtimeをproject設定で有効化 | Developer ID署名・公証済み配布物、別Mac検証の完了を意味しない |

## Experimental AI基盤の境界

[AI_INTEGRATION.md](AI_INTEGRATION.md)とD-043は、AIを出荷した記録ではなく実装前の技術契約である。D-040の開発順を変えず、Package Validator GateとExternal Change / Conflict Gateを引き続き出荷作業として優先する。

現在のAI実装で完成扱いにできる範囲は、`NovelAI`のpure domainに加え、EditorKitのIME／surface／revision／Undoを守るselection transaction、document session／episode／source digestをproviderへ渡さないApp local context、送信前／適用前stale、one-shot、cancel後の遅延完了破棄、fake provider、provider-neutralな共通UI、本文送信前attestationを持つCodex sidecar v1のNode／Swift mock protocolまでである。共通UIはexact preview、requestごとの確認、進行／cancel、原文との差分、stale、Copy、明示Applyを提供し、`FUMINIWAExperimental`だけに存在する。通常版は`NovelAI` dependency、compile flag、Experimental sourceを生成project監査で除外する。protocol mockはSDK／CLI、credential、network、実provider processを起動しないため、これはCodex／OpenRouterが利用可能または公開可能という意味ではない。

domainで実装済みのhard guardは、app-provided inputとraw structured output、stream delta、decoded resultの文字数／UTF-8 byte数、注意点20件上限、wall-clock timeout、result usageの検証である。細切れdeltaはdomainでboundedに集約してUI更新数を抑える。providerはstreaming／cancellation／usage reportingを必須とし、`outputTokens`は必須かつ非負、`inputTokens`は省略可能だが存在時は非負としてfail-closedにする。ただしusageは事後報告であり費用capそのものではない。実providerの`maximumOutputTokens`相当parameter、実送信直前payload capture、wire event byte／件数、process resource limitはadapter Gateであり、現在は未実装である。

Codex adapterはprovider実装／更新時に再確認したstable（非alpha）TypeScript SDKのexact versionを使う署名済みbundled Node sidecarを候補とする。2026-08-09の調査baselineは`0.147.0`だが、通信成功だけでは出荷可能としない。SDK／依存／Node／Codexのhash固定、request専用empty cwdと`skipGitRepoCheck: true`／専用`CODEX_HOME`、environment allowlist、Keychain、OS-level file-read隔離、Abort後のprocess tree回収とorphanなし、arm64／x86_64、nested signing、Hardened Runtime、公証を実機で証明するまで非出荷・UI非表示とする。実repositoryや検査回避用の偽Git repositoryをcwdにしない。公開SDKにephemeral thread optionが確認できないため、FUMINIWA側のresultがmemory onlyでも「履歴非保持」と表現しない。

provider／service側の保持期間と学習利用、SDK／CLIが`CODEX_HOME`、cwd、temporary directory等へ作るartifactの場所・範囲・保持期間、providerの料金単位とrequest上限の一次資料根拠は、AI UI前の技術Gateとして未実装である。これは価格戦略の検討ではなく、利用者が1 requestの送信先・保持・利用上限を確認できる機能要件である。

OpenRouterは別adapter／別PRとし、Codex failureからもOpenRouter内部routingからも自動fallbackしない。送信先を変更するときはexact previewと明示確認を取り直す。純粋domainと隔離PoCは非出荷のまま並行してよいが、出荷UI、menu、shortcut、設定入口を先行させない。

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
