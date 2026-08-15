# Codex SDK sidecar隔離feasibility 実装レポート

**基準日: 2026-08-09 / 現在の扱い: D-075で実装・fixture・testを削除した履歴資料。実provider統合は最新stable SDKの明示再評価まで延期**

本書は、ふみにわ（FUMINIWA）の個人用Experimental AIとして調査・実装したCodex SDK sidecar隔離feasibilityを、再開時に検証可能な形で残す日付固定の結果記録である。現在の製品ロードマップや実行承認ではない。延期判断は[D-054](DECISIONS.md)、当時の詳細な技術契約は[AI_INTEGRATION.md](AI_INTEGRATION.md)を正とする。

## 1. 結論

- Node／Swift mock protocolからB4-Dのabstract interactive sequencingまで、本文を送らない合成checkpointを実装した。
- B4-D時点でもproduction catalogは空で、具象production channel／factory／callsite、実Node／SDK／CLI接続、network、API key、実原稿送信は0件である。
- B4-Cのchildはidentity観測後もresumeされずkill／direct reapされ、B4-D transportへ変換されていない。
- B4-Dはin-memory mock channelのsequencing feasibilityであり、実runtime B4-Dの完了、Codex利用可能、AI対応、公開可能のいずれも意味しない。
- B4-E以降を独自に積み増す作業は停止し、将来の公式stable SDK／APIがより小さく検証可能な境界を提供した時点で、明示的に再評価する。
- 実装済みコード、fixture、testはD-075で削除した。NO-GO境界、検討結果、当時の検証値だけを調査履歴として保持する。

## 2. 目標と非目標

調査の目標は、利用者が確認した選択本文をCodexへ渡す前に、prompt、runtime identity、artifact、process、cancel、cleanupをfail-closedに拘束できるかを、小さいcheckpointへ分けて確かめることだった。

この調査中に目標としなかったもの:

- 実providerへの通信
- API keyまたは実原稿の使用
- 通常版`FUMINIWA`へのAI入口、provider dependency、sidecar artifactの追加
- 一般公開、履歴非保持、zero retention、orphan-free、anti-rollbackの宣言
- B3 candidateやruntime observationからproduction approvalを自動生成すること

## 3. 実装したcheckpoint

| Checkpoint | Commit | 固定した範囲 | 完了を意味しない範囲 |
| --- | --- | --- | --- |
| Sidecar protocol v1 | `e64ad09` | content-free `hello`／`ready`、sealed `start`、strict JSONL、上限、terminal | 実SDK、process、network |
| SDK合成capture／manifest v1 | `4ef5f6a` | SDK／CLI 0.147.0のargv、stdin、schema、usage、cancel、canonical manifest | 採用runtime、実通信 |
| Darwin supervisor B2 | `f1618ea` | 合成helperのprocess group、pipe cap、TERM→KILL、direct child reap | grandchild reap、parent-death、実SDK tree |
| Packager／native verifier B3 | `85c268a` | arm64固定21 fileのcandidate、canonical digest、mutation rejection | approval、exact Node、immutable use |
| Approval contract B4-A | `ea2cd70` | native policy shape、inventory role、private identity、空catalog | approved runtime、anti-rollback |
| Exact Node inspector B4-B | `7794459` | 非実行のpath／SHA-256／Mach-O／Security observation | actual process、Node version、launch capability |
| Suspended identity probe B4-C | `c19d4b7` | actual PID／dynamic code identityのprobe、resumeなし、kill／reap |実行承認、adversarialな外部resume拒否 |
| Abstract interactive transport B4-D | `e5022f3` | content-free open、exact `ready`後だけのsealed `start`、terminal／EOF、race／cleanup | 具象process transport、OS containment、実原稿 |

これらのcommitはcheckpointの追跡用であり、単独または合算してproduction runtimeのapproval tupleを構成しない。

## 4. B4-Dで固定した事実

- 引数を持たないcontent-free factoryがfreshな1-request／class-bound channelを返すabstract契約
- process-wide weak registryによるlive channel reuse拒否と、duplicateの先行owner非破壊
- sealed payload budgetだけから`run`開始時に固定するabsolute request deadline
- 30秒以下の独立attestation timeout
- `hello`だけを先に書き、exact request／runtimeの単独`ready`とframe boundaryが一致した後だけsealed `start`を1件書く順序
- `started` → 単一terminal → exact EOFと、terminal観測後最大1秒のEOF drain
- cancel／timeoutのfirst-wins、atomic channel cancellation、cleanup safety error優先
- factory／channelの生error、path、contentを上位へ漏らさない分類済みerror

固定したのはabstract mock channelに対する順序とraceだけである。actual Node、SDK、CLI、process identity、approval、loader closure、OS read／exec policyとの結合はない。

## 5. 検証記録

最終checkpoint時点で次を確認した。

- B4-D 5 suites: **54 / 54 pass**
- `FUMINIWAExperimental`全体: **205 / 205 pass**
- `./Scripts/check.sh`: **All checks passed**
- B4-D差分の最終security review: reportableなP0／P1／P2なし
- 通常版targetは`NovelAI`、Experimental AI source、provider artifactをbuild graphへ含めない

これは2026-08-09の実装snapshotに対する証拠である。将来のSDK、Node、macOS、署名済みArchiveへ自動的に引き継がれない。

### 保存中Experimental testの既知の不安定性

clipboard支援へ切り替えた後の全体再検査では、上記snapshotと同じ205件が完走する回と、既存の`shutdownDrainsEveryRegisteredRoute`が終了処理中に待ち続ける回を観測した。停止時のsampleでは、`AIProofreadingOperation.cancel()`から`AIProviderEventContinuation.consumerCancelled()`へ入る経路と、別taskの`yieldStarted()`が`AsyncStream`へ配送する経路が互いのlockを待っていた。通常版clipboard経路、`NovelAppTests`、EditorKit selection command、Node sidecar testにはこの経路への依存も実行もない。

この競合は実providerを再開する前に、lock内では状態遷移と送出actionだけを確定し、`AsyncStream.Continuation.yield`／`finish`とupstream handlerをlock外の直列emitterで実行する形へ再設計し、cancelとのbarrier testで固定する必要がある。D-054でprovider実装を延期したため、今回のclipboard機能へ修正範囲を広げず、保存中Experimentalコードをproduction-readyと扱わない根拠として記録する。

## 6. 未達のGate

実原稿を安全に送るには、少なくとも次が未達だった。

- B4-Eのclosed linker／loader、native broker／helper、approval／actual identity／OS-level read／exec policyの不可分な結合
- complete loaded artifact inventoryと、検証済みbytesを実際のimport／path-based spawnへ拘束するimmutable verify-to-use
- same-UIDによるancestor／root swap、外部`SIGCONT`、mapped-vnode／in-place mutationへの実証済み対策
- exact Node versionとB4-B SHA／B4-C actual process／approval authorityの結合
- request専用empty cwd／`CODEX_HOME`、environment allowlist、Keychain one-shot credential delivery
- tool、shell、web、MCP、additional directoryの制御とOS-level file-read拒否
- SDK／CLI local artifactの完全な場所、内容範囲、保持期間
- process memory／CPU／件数、wire event、upstream output token／費用の実上限
- group脱出拒否、app crash／`SIGKILL`／power loss後を含むparent-death回収
- arm64／x86_64、nested signing、Hardened Runtime、公証、Gatekeeper、clean Mac QA
- provider／service側のsession保持、学習利用、保持期間の確証と利用者表示

## 7. 延期した理由

調査baselineのTypeScript SDK 0.147.0はCLI processを介し、安全な組込みにはNode、JavaScript module、CLI、runtime data、process tree、filesystem、credentialをFUMINIWA側で広く閉じる必要があった。公開APIでtool完全無効化、upstream output token cap、ephemeral／non-persistent threadを確認できず、FUMINIWAのlocal上限をそれらの代替とは扱えなかった。

合成captureでは、literal U+2028／U+2029を含む同じCLI JSONL出力がNode 22.23.1ではround-tripし、Node 26.4.0ではSDK内部で分断される差も観測した。`Node >= 18`だけでは互換性条件にならず、採用時点のexact組合せを再検証する必要がある。

通信機能そのものより隔離runtimeの独自実装が大きくなったため、現行SDKへ設計を固定し続けるより、公式境界が更新されてから再評価する方が保守性と原稿安全の両面で合理的と判断した。これは失敗したコードを捨てる判断ではなく、未達Gateを誤って完成扱いにしない判断である。

## 8. 保持する成果と凍結境界

次をリポジトリへ保持する。

- `NovelKit/Sources/NovelAI`とその契約test
- `NovelAppExperimental/AI`のfake UI、Codex protocol／manifest／approval／identity／synthetic transport primitive
- `NovelAppExperimentalTests`の合成test
- `Sidecars/Codex`のprotocol、manifest、supervisor、合成capture／packager資産
- 通常版target分離を検査するscriptとXcodeGen構成
- D-043、D-046〜D-053と本レポート

保持中も次を維持する。

- production catalogは空
- B4-C childをresumeしない
- B4-Dにproduction channel／factory／callsiteを追加しない
- 実SDK／CLI、network、API key、実原稿を使わない
- 通常版へ`NovelAI`、Experimental source、provider dependency／artifact／menu／shortcutを混入させない

## 9. 再評価の開始条件

provider統合は、利用者が明示的に再開を決めた場合だけ新しいDecisionから始める。その際は次を行う。

1. 公式一次資料とstable packageを再取得し、現行のSDK／native API／app-server境界を比較する。
2. exact SDK／CLI／Node version、package integrity、tool surface、session persistence、output cap、cancel、error内容、local artifactを再captureする。
3. 旧0.147.0のhash、Node compatibility、B3 candidate、B4 observationを採用値として再利用しない。
4. 公式により小さい安全境界が提供されていれば、旧Node sidecar architectureを維持せず再設計する。
5. 新しいthreat model、Decision、受け入れtestを先に固定し、実原稿、credential、networkは最後のGateまで使わない。

## 10. 当面のAI支援

通常版ではproviderを組み込まず、校正／アドバイス用のプロンプトを利用者の明示操作でsystem clipboardへコピーする。利用者は任意のAI chatへ手動で貼り付ける。対象scope、clipboard共有境界、非目標は[CLIPBOARD_AI_ASSIST.md](CLIPBOARD_AI_ASSIST.md)を正とする。
