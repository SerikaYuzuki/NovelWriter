# AI統合 技術契約

**状態: pure domain、EditorKit transaction、App local context、fake provider、Experimental共通UI、target分離、Codex sidecar protocol v1、manifest v1のNode純粋primitive、exact SDKの合成CLI capture、合成helper用Darwin native process supervisorまで実装 / 実Codex・OpenRouter provider、実CLI／network、native manifest verifier、Keychain、OS隔離、parent death後の回収は未実装**

本書は、ふみにわ（FUMINIWA）へAI支援を追加するときの実装境界と安全条件を定める。個別判断は[DECISIONS.md](DECISIONS.md)のD-040 / D-043 / D-046 / D-047 / D-048、AIの実装順は[DESIGN.md](DESIGN.md)、公開Releaseの技術Gateは[COMMERCIALIZATION_IMPLEMENTATION.md](COMMERCIALIZATION_IMPLEMENTATION.md)を正とする。

この契約を文書化したことや純粋domainを追加したことは、AI機能、Codex接続、OpenRouter接続、履歴非保持、配布可能性の完成を意味しない。

## 1. 製品原則

1. **AIなしで完結する。** アカウント、API key、ネットワーク、provider契約なしで、既存の執筆、保存、検索、snapshot、TXT / Markdown / EPUB書き出しを使える状態を維持する。
2. **初回機能は「選択範囲の校正案」だけに絞る。** 利用者が本文中で明示的に選択した文字列以外の本文、作品名、章／話名、メモ、人物、プロット、世界観、資料、ローカルファイルを暗黙に文脈へ加えない。
3. **送信前にexact previewを出す。** version付きinstruction ID、`selected_text`を未信頼の本文データとして扱い、その中の命令に従わず選択外の文脈／ファイルを参照しない固定指示、空白／改行／約物を保持した選択文字列から、domainがadapterへ渡す単一の`applicationPrompt`を決定論的に生成する。domainはversion付きresponse schema ID（初版`proofreading-result-v1`）とexact `applicationResponseSchema`も固定する。previewではprompt／schemaのexact contentと内訳、送信先provider、model、送信範囲、app-provided inputの文字数／byte数、保持／学習利用について技術的に確認できた表示を併記する。instructionまたはschemaを変える場合は対応IDも更新し、確認後にprompt、schema、いずれかのID、providerまたはbudgetが変わった場合は確認を無効にする。
4. **明示確認なしに送らない。** 設定画面での同意だけを送信同意として使わず、requestごとに利用者が「送信」を選ぶ。自動再送もしない。
5. **結果はmemory onlyで受け取る。** 初期版ではprompt、選択本文、応答、差分をFUMINIWAの永続ストア、UserDefaults、ログ、snapshot、`.novelpkg`へ保存しない。これはFUMINIWA側の保存範囲だけを表し、provider側またはSDK側の保持がないという主張ではない。
6. **自動適用しない。** 結果は原文との差分として確認し、利用者が明示的に適用するまで本文もモデルも変更しない。
7. **古い結果を適用しない。** request後に作品session、editor surface、対象話、対象範囲、対象文字列のいずれかが変わった結果はstaleとし、適用をfail-closedで拒否する。結果の閲覧とコピーは許可してよい。
8. **`.novelpkg`を変更しない。** AI設定、prompt、応答、差分、provider情報をpackage schemaへ追加しない。`NovelDocument`や保存形式のversionも上げない。
9. **providerを勝手に切り替えない。** Codexの失敗、timeout、rate limit、認証失敗をOpenRouterへ自動fallbackしない。provider変更は利用者の明示操作と、新しい送信先を示すpreviewの再確認を必要とする。
10. **未確認の保持／利用上限をUIで補わない。** provider／service側の保持期間と学習利用、SDK／CLIがlocalに作るartifactの場所・範囲・保持期間、providerの料金単位とrequest上限は一次資料と実測で確認する。個人用Experimentalでは確認済み値と未保証を送信前に区別し、公開Releaseでは根拠を固定する。未確認値を「履歴なし」「無料」「上限あり」等として表示しない。
11. **providerが違っても操作作法を分岐させない。** Codex SDKとAPI経路（初期はOpenRouter）は、同じ選択snapshot、exact preview、送信確認、進行／cancel、結果、diff、stale、Copy、明示ApplyのUIとoperation orchestratorを使う。provider固有のtransport、credential、model設定、保持情報、errorだけをadapterへ閉じ込める。
12. **個人用Experimentalと公開Releaseをbuild graphで分ける。** 個人利用中は、実処理と安全条件を満たしたAI UIを別app target／scheme `FUMINIWAExperimental`で先行できる。通常の`FUMINIWA` app targetはcompile flag、target dependency、resource copyの段階でAI入口とprovider artifactを含めず、runtime flagだけに依存して隠さない。target／scheme／bundle ID／既定保存rootの分離と生成projectの機械監査は実装済みである。Experimentalは旧製品のrecent URL／設定を自動移行せず、既存作品は利用者が明示的に開く。実sidecar追加時と公開判断時には両Archiveのgraph／bundle inventoryを再検証する。

## 2. 最初の利用フロー

```text
Editorで範囲選択
  → 校正を要求
  → IME確定済みの選択snapshotを取得
  → provider / modelを明示選択
  → applicationPromptとapplicationResponseSchemaのexact preview
  → 利用者が送信を明示確認
  → providerへ1回送信
  → 校正案と局所diffをmemory上に表示
  → 現在の原文とidentityを再検査
  → 利用者が明示適用
  → EditorKit commandとして1回のUndo単位で置換
```

- 未確定の日本語IME入力がある間はsnapshotを取らず、EditorKitの公開command境界で確定とモデル同期が完了してから選択を得る。
- 選択が空、無効なUTF-16範囲、上限超過、または現在のeditor surfaceから取得できない場合は送信しない。
- previewはversion付きinstruction ID、固定指示、exact selected text、version付きresponse schema IDに加え、domainが生成した単一`applicationPrompt`とexact `applicationResponseSchema`そのものを表示できなければならない。Unicode正規化、改行変換、前後のtrim、近傍文の追加をpreview後に行わない。
- Adapterはconfirmed requestの`applicationPrompt`へ再構築、template化、追記を行わず、providerへ渡す論理文字列を完全一致させる。`applicationResponseSchema`はdomainのversion付きcanonical JSON literal／digestと完全一致する場合だけstrictにparseし、providerが要求するJSON objectへ写像する。送信前captureではcanonical再encodeまたはJSON value treeがsealed schemaと一致することを検証し、property追加・削除・緩和を禁止する。HTTPやSDK wrapperのescape／key順を含むwire全体のbyte一致を、schema内容の一致と混同しない。選択本文以外の原稿データをhidden promptやmetadataへ入れない。
- provider完了時はraw structured outputとusageをdomain境界へ渡し、`proofreading-result-v1`のexact schemaでstrict decodeした`AIResult`だけを結果として扱う。adapterがSDKの任意decode値から`AIResult`を直接作って検証を迂回しない。
- confirmed requestはdomain所有executorのone-shot leaseを共有し、copyや並行呼出しでも最初の1回だけprovider実行権を取得できる。preflight失敗やcancelでは開始しない場合もあり、provider `start`は最大1回である。再試行は同じconfirmed値を再利用せず、新しいpreviewと明示確認から始める。
- preview確定時にrequestのdigestを作り、送信直前にもsessionと選択snapshotを再検査する。preview後に対象が変わった場合は送信せず、更新後のpreviewへ戻す。
- 送信中も本文編集を妨げない。編集によって結果がstaleになっても、進行中requestが別の本文や別作品へ再束縛されてはならない。
- cancel後に届いた完了、過去requestの遅延完了、画面を閉じた後の完了はrequest IDで破棄し、結果表示や本文を復活させない。
- provider失敗時は原文を維持し、認証、接続、timeout、上限、provider拒否、不正応答、cancelを型付きで区別する。stderrや生の応答をそのまま利用者向けエラーやログへ出さない。

## 3. Local snapshotとconfirmed outboundの分離

1回の校正操作は、アプリ内だけで保持するlocal operation contextと、providerへ渡してよいconfirmed outbound requestを別の値として持つ。この2つを一つの型へ統合しない。

local operation contextは、少なくとも次の不変snapshotを持つ。

| 値 | 目的 |
| --- | --- |
| request ID | cancel済み／古い非同期完了を識別する |
| document session token | 開く、新規、復元、別名保存等で作品世代が変わったことを検出する |
| editor surface token | 同じ話IDでもeditorの再生成、別surface、dismantleを検出する |
| chapter / episode identity | 対象話を固定する |
| UTF-16 selected range | `NSTextView`の選択範囲と安全に照合する |
| exact selected text | previewと送信内容の正とする |
| source digest | 現在の対象substringが同一かを適用前に検証する |
| provider / model / application instruction ID / response schema ID | 確認した送信先、固定指示、応答契約の版を固定する |
| provider disclosure snapshot | runtime／tool制御／upstream cap／session保持／隔離／local artifact／routing制約の確認状態と版を固定する |

このlocal operation contextはApp / EditorKit bridgeのmemoryにのみ置き、provider adapter、wire request、prompt、providerのsession metadataへ渡さない。特にdocument session token、editor surface token、chapter / episode identity、UTF-16 range、source digest、file URL、pathを`AIConfirmedRequest`へ追加してはならない。

providerが受け取れるのは、明示確認済みの`AIApplicationPayload`を封印したoutboundだけである。初回の`AIConfirmedRequest.outbound`が含むのは、previewしたprovider descriptor、purpose、application instruction ID、domainが生成した単一`applicationPrompt`、response schema ID、exact `applicationResponseSchema`、hard budget、promptとschemaを合計したapp-provided inputの文字数／UTF-8 byte数だけとする。raw instructionとexact selected textを別口でconfirmed outboundへ持たせず、previewの内訳から封印済みpromptを再結合しない。request IDやprovider disclosure snapshotを含むlocal confirmation／routing情報はApp側のmemoryで管理し、providerへ原稿identityやmetadataとして送らない。disclosure revision、provider、model、runtime、routing制約がpreview後に変わった場合も確認を無効にする。adapterはconfirmed outboundのprompt／schemaにhidden context、metadata、instructionを追加しない。

適用できるのは、同じdocument sessionと同じ生存中のeditor surfaceがactiveであり、同じepisodeを表示し、rangeが現在の本文で有効で、そのsubstringがlocal snapshotのexact textおよびdigestと一致するときだけである。判定中に対象を現在選択へ読み替えたり、同じ文字列を周囲から再検索したりしない。

適用はモデル配列を直接書き換えず、EditorKitの公開commandとして対象`NSTextView`へ渡す。IME marked text中は拒否または確定後に再確認し、置換とモデル通知をexactly onceで行い、1回のUndoで原文へ戻せることを統合テストで保証する。

## 4. 純粋domain境界

純粋domain PRで実装した範囲は、providerとUIから独立した`NovelAI`のprovider-neutral outbound契約だけである。名称を含む実際のtargetと公開APIは実装diffを正とし、本書から存在しない機能を補わない。

純粋domain PRに含めたもの:

- payload／response、provider descriptor、budget、型付きerrorの値型と、preview／confirmed requestのone-shot capability
- 未確認draftからversion付きinstruction ID、単一`applicationPrompt`、version付きresponse schema ID、exact `applicationResponseSchema`を含むpreviewを作り、明示確認後にだけprovider／purpose／budget／app-provided input countとともに`AIApplicationPayload`をsealed confirmed requestへ移すoutbound状態遷移
- provider-neutralな非同期event stream protocolとcancel／terminationの契約。provider descriptorはstreaming、cancellation、usage reportingを必須能力とする。ここでstreamingはstarted／terminalを非同期に受けるevent streamを表し、providerが部分的な置換本文を返すことまでは保証しない
- adapterの外側で不変O(1)のprovider descriptorを照合し、confirmationのone-shot lease、cancel済み／stream破棄後のprovider実行権または外部副作用の開始拒否、executor呼出しからのwall-clock timeoutを所有するdomain executor
- raw structured outputをexact schemaでstrict decodeして`AIResult`へ変換し、schema外key、欠損、型違い、不正usageをfail-closedにする完了境界
- 初版`proofreading-result-v1`は、`replacement: string`、`summary: string`、`warnings: string[]`の3項目をすべて必須とし、追加propertyを拒否するobject schemaとする。schema shapeとは独立したdomainのrequest budgetとして注意点件数上限をconfirmed payloadへ封印し、送信前UIへ表示する。初期値とabsolute maximumはいずれも20件で、超過responseを結果UIへ渡さない
- app-provided input、raw structured output、stream delta、decoded resultの文字数／UTF-8 byte数、注意点件数、wall-clock timeout、result usageを強制するdomain budget。細切れdeltaはdomain境界でboundedなまとまりへ集約し、内容を欠落させずUI更新回数を制限する
- 決定論的fake provider、sealed payload一致、成功／provider不一致／consumer cancel／timeout／budget超過の契約テスト

含めないもの:

- SwiftUI、AppKit、`NSTextView`、AppState、EditorKit commandの実装
- document session、editor surface、episode、range、source digestを持つlocal operation contextとstale判定
- `URLSession`、Node、subprocess、Codex SDK、OpenRouter SDK、Keychain
- provider用API key、実通信、実model名、prompt本文の永続化
- `.novelpkg`、NovelStorage、snapshot、UserDefaultsの変更
- 出荷UI、menu、toolbar、shortcut、設定画面、feature flagの利用者向け露出

SDK固有型やHTTP／processのerror型をdomain APIへ漏らさない。provider adapterはdomain protocolへ適合し、Experimental専用compositionが明示的に1つを選んで注入する。共有`AppDependencies`へproviderを追加しない。provider descriptorは実行中に変化せず、I/O、lock待機、actor hopを行わないO(1)の値とする。完了usageの`outputTokens`は必須かつ非負、`inputTokens`は不明なら省略可能だが存在時は非負とし、欠損／不正値はtyped failureにする。usageは生成後の事後報告であって、それ単独では費用capにならない。domain層自身はfallback、retry、provider選択、永続化を行わない。EditorKit transactionとApp-level document session／episode／source digestのlocal-only validatorは実装済みであり、confirmed outboundの型はlocal identityで太らせない。

## 5. Provider順序と分離

実装順は次のとおりとする。これは自動fallback順ではない。

1. **Codex SDK adapter**: 第一候補。公式TypeScript SDKを固定protocolのNode sidecarから使用する。個人用Experimentalはversion／pathを検査した開発用runtime、公開Releaseは署名済みbundled runtimeを使う。
2. **OpenRouter adapter**: 第二候補。Codex adapterと別target／別具象型で実装し、provider-neutral domain protocolだけを共有する。

利用者が選んだadapterだけを1 requestに使う。Codexが利用不能でもOpenRouterを呼ばず、OpenRouter内でもmodel/provider routingのfallbackを無効にしてfail-closedにする。providerを変える場合は、送信先、model、保持期間／学習利用、料金単位／request上限の確認済み表示を更新し、exact previewから明示確認を取り直す。

App側はprovider-neutralな`AIProofreadingOperation`相当のorchestratorを一つだけ持ち、Editor snapshotとlocal identity、domain request、表示状態を結合する。UIはproviderごとの画面を作らず、provider選択とprovider固有の確認情報だけを差し替える。Codexのprocess状態やOpenRouterのHTTP response型をSwiftUIへ渡さず、どちらも同じtyped event／errorへ写像する。

## 6. Codex Node sidecarのExperimental／公開Gate

公式のCodex TypeScript SDKはNode.js向けであり、Swift-native SDKではない。[公式README](https://github.com/openai/codex/tree/main/sdk/typescript)はSDKがCodex CLIをspawnし、JSONLで通信する構成とNode.js 18以降を示している。FUMINIWAではSwiftからSDKやCLIを直接呼ぶのではなく、固定protocolを持つNode sidecarを候補とし、公開Releaseではそのruntimeとsidecarをbundleして署名する。

Swift／Node間のwire形式とstate machineは[`Sidecars/Codex/PROTOCOL.md`](../Sidecars/Codex/PROTOCOL.md)を正とする(D-047)。本文を含まない`hello`／`ready`でruntime identityを検査してからだけ`start`を許可し、valid start後は`started`と単一terminalを返す。v1はtoken deltaを捏造せず、Codex結果本文は完了後だけ共有UIへ渡す。protocol mockの成功を実SDK接続、隔離、orphanなしの証明として扱わない。

canonical deployment manifest v1の正は[`Sidecars/Codex/MANIFEST.md`](../Sidecars/Codex/MANIFEST.md)とする。現在は合成treeのcanonical bytes／root digestと改ざん拒否をNodeで固定した段階であり、実配布rootのallowlist copy、nativeの起動前検証、完全なloaded-module inventory、verify-to-import競合は未実装である。

2026-08-09時点の調査baselineは公式npmのstable（非alpha）`0.147.0`である。Checkpoint B1で`@openai/codex-sdk` `0.147.0`と対応CLI packageをlockfileへexact pinし、実通信しない合成CLIだけでargv／stdin／schema temporary file／environment／usage／cancel／errorをcaptureした。これは恒久採用versionではなく、provider実装／更新PRごとに公式公開物を再確認し、その時点でreviewしたstable non-alphaをexact pinする。semver range（`^0.147.0`等）は使わず、更新ごとにprotocol capture、tool surface、artifact、cancel、sandbox Gateを再実行する。

Darwin native process supervisorの正は[`Sidecars/Codex/SUPERVISOR.md`](../Sidecars/Codex/SUPERVISOR.md)とする(D-048)。Checkpoint B2では、canonicalなabsolute executable／cwdと明示environmentを`posix_spawn`し、childを新process group leaderにするExperimental-only primitiveを、合成shell helperだけで検証した。stdin／stdoutは512 KiB、stderrは16 KiBを上限とし、stderr内容をresultへ保持しない。timeout／cancel／cap failureはfirst-winsでclaimし、同一groupへTERM→KILL、direct childだけを`waitpid`でreap、reap後の`ESRCH`をboundedに観測する。実SDK／CLI、network、credential、native manifest verifier、OS-level sandboxは使っておらず、実送信はNO-GOのままである。

### 6.0 二段階のGate

- **個人用Experimental Gate**: Editor bridgeの誤適用防止、exact SDK／CLI／Node version・実行path・cryptographic hashとlockfile／package integrity、request専用cwd／`CODEX_HOME`、environment allowlist、Keychain、OS-level file-read拒否、本文等を残さない診断、cancel／timeout／終了時のprocess tree回収、local artifact inventory、wire／event／time／process上限を実機で通す。これを満たした実処理だけを`FUMINIWA_ENABLE_EXPERIMENTAL_AI`付き`FUMINIWAExperimental` app targetの同一AI UIへ出してよい。
- **公開Release Gate**: Experimental Gateに加え、runtime／SDK／CLI／sidecarのbundle固定と起動前hash検証、arm64／x86_64、nested signing、Hardened Runtime、Archive、notarization、stapling、Gatekeeper、clean Mac更新検証をすべて通す。通常の`Release`へAIを含める判断は別のDecision更新を必要とする。

個人用Experimentalでは、開発機に明示的に用意したNode／sidecarを使ってよく、universal bundle、署名、公証をUI開発の前提にしない。ただし実行path、version、cryptographic hashとlockfile／package integrityを固定・検査し、ambientなglobal Node／Codex、通常の`~/.codex`、作品repository、親environmentへ暗黙fallbackしない。Experimentalで省略できるのは配布成立の検証だけで、原稿、credential、supply-chain identity、file access、process lifecycleの安全条件ではない。

### 6.1 Supply chainと配布物

- Experimentalでもlockfileを正とし、SDK／transitive dependencyのpackage integrity、CLI／Node／sidecarの採用version、実行path、cryptographic hashを記録する。実行時のversion、path、hashが期待値と異なる場合は送信前に拒否し、別のglobal installへfallbackしない。
- 公開Releaseではnpm installやruntime downloadを利用者環境で行わず、lockfileとvendor済み成果物から再現可能に組み立てる。
- 公開ReleaseではCodex SDK、全transitive dependency、Node runtime、Codex CLI executableのexact versionと公式integrity／cryptographic hashをallowlistで固定し、起動前にも改ざんを検出する。
- 公開ReleaseではNode runtime、sidecar script/bundle、Codex CLI、必要なnative artifactをアプリbundle内の決めた場所にのみ同梱する。
- 公開Releaseではhelperとすべてのnested executable／libraryをDeveloper IDで適切に署名し、Hardened Runtime、Archive、notarization、stapling、Gatekeeper検証をアプリ全体で通す。
- 公開Releaseではarm64とx86_64の各clean Macで、初回起動、実request、cancel、更新後起動を検証する。片方のarchitectureだけの成功でuniversal配布可能としない。

### 6.2 原稿とローカルファイルの隔離

- requestごとに、空で新規作成した専用`cwd`と専用`CODEX_HOME`を使い、SDKへ`workingDirectory = request専用empty cwd`と`skipGitRepoCheck: true`を明示する。作品package、実repository、Documents、利用者HOME、通常の`~/.codex`をcwdやadditional directoryにせず、Git検査を通すためだけの偽repositoryを`git init`しない。
- 親processのenvironmentを継承しない。sidecar起動に必要な`CODEX_HOME`、専用temporary path、locale等を明示allowlistで組み立て、API key以外のtoken、proxy、Git、SSH、cloud credentialを渡さない。
- API keyはKeychainへ保存し、request時だけ子processの許可された入力として渡す。sidecarをkey入りargv／environmentで起動せず、artifactの独立検証とcontent-free `ready`一致後に、native supervisorが所有する別のone-shot anonymous pipeで渡す。pipeは対象process tree以外へ継承せず、delivery後と終了時にcloseする。ファイル、通常JSONL protocol、command line、ログ、UserDefaults、crash metadataへ書かない。
- 利用中SDKが公開する範囲でtool、shell、web search、skill、MCP、additional directoryをすべて無効化し、校正用の固定input/output schema以外を受け付けない。公開APIで無効化できない能力があるExperimental実行はその事実をpreviewへ表示し、OS-level sandboxの拒否試験を必須にする。無効化できたとは表現せず、公開Release Gateは未達のままとする。
- empty cwdだけではファイル隔離にならない。D-011によりアプリ本体がApp Sandboxを使わない現状では、子processも通常は利用者権限で他のファイルを読める。採用するOS-level sandboxで許可したcwd／`CODEX_HOME`／必要runtime以外の作品package、HOME、Documents、repositoryを読めないことを、拒否試験とfile-access traceで証明する。
- 「workspace-write」「approvalしない」「promptで読むなと指示する」だけを隔離の証明として扱わない。

### 6.3 Lifecycle、取消、resource limit

- SDKの`AbortSignal`へcancelを伝播し、短いgrace period後にsidecarとそこからspawnしたCodex process treeを終了する。
- 正常終了、error、timeout、cancel、通常のアプリ終了では、監査済みlauncher／supervisorが所有するprocess groupへsignalし、direct childのreapとpost-reap group空観測をPID追跡付き統合テストで確認する。macOSの親はgrandchildを`waitpid`／reapできないため、同一group descendantは終了観測までに限定する。appの`SIGKILL`／crash／power loss、`setsid`／`setpgid`等のgroup脱出はsame-process supervisorでは回収できず、独立helperまたは同等のOS lifecycle／containment Gateなしに一般的なorphan-freeを主張しない。
- domainが強制するapp-provided input／raw response／delta／decoded resultの文字・UTF-8 byte上限とwall-clock timeoutに加え、adapterは利用中SDKが上流の`maximumOutputTokens`相当parameterを公開する場合、confirmed budgetから必ず設定する。実送信直前のSDK requestをcaptureするテストで値を確認し、usageの事後検査だけへ依存しない。
- 利用中Codex SDKがupstream maximum output tokenまたはtool完全無効化を公開していない場合、個人用Experimentalでは「上流capなし／tool能力未保証」を送信前に明示したうえで、OS-level file隔離とFUMINIWA側のwire／event／time／process上限を強制して検証できる。ただしこれを上流token／費用capやtool無効化の代替と表現せず、公開Release Gateは未達のままとする。
- wire上のinput／output byte数、1 event byte数、event件数、wall-clock timeout、同時request数、process memory／CPU等の上限をadapter／sidecarで固定し、超過時はprocess treeを止め、原稿を変更せず型付きerrorにする。pure domainのbudget実装だけでこのGateを完了扱いにしない。
- SDK内部JSONLもprotocol外の別境界として検証する。exact allowlist候補のNode／SDK／CLI組合せで、選択本文とstructured outputにliteral U+2028／U+2029を含むrequestをround-tripし、record分断、parse error、本文変化が起きる組合せは送信前にrejectする。外側sidecarのLF scannerだけでSDK内部framingを保護できたと扱わない。
- 0.147.0の合成captureでは、CLI stdout内にliteral U+2028／U+2029を含む同じvalid JSONLが、Node 22.23.1ではexact round-tripし、Node 26.4.0ではSDK内部`readline`で分断されparse failureになる差を再現した。入力stdinは両方でbyte一致する。したがって`Node >= 18`だけをruntime条件にせず、exact Node version／path／hashとUnicode probeの結果をattestation allowlistへ固定する。Node 26.4.0の現組合せはNO-GOであり、互換Nodeまたは監査済みlauncher shimを選んでも他のprocess／隔離Gateは残る。
- 同じcaptureで、nonzero exitのstderr、`turn.failed`のmessage、malformed stdoutの生値がSDK errorへ含まれることを確認した。adapterはそのerrorをUI／domain／logへ渡さず固定codeへredactする。`AbortSignal`の実証もdirect childへの`SIGTERM`到達までであり、exit待ち、SIGKILL、descendant回収の証明ではない。
- B2 supervisorはrequest timeoutをterminal claimのabsolute deadlineとし、その後も別のbounded deadlineでTERM／KILL、direct child回収、pipe drainを続ける。したがって`run`総wallはrequest timeoutを超え得る。leaderの自然終了後にlive descendantが観測された場合はcleanup後も`lingeringDescendant` failureとし、成功へ戻さない。
- B2ではstdin／stdoutを各512 KiB、stderrを16 KiBに固定した。stderrは内容をresult／通常ログへ保持せずbyte countだけを返し、超過errorの`actualAtLeast`は観測した下限とする。secure erase、childのmemory／CPU／process件数、SDK内部record、upstream token／費用上限をこれで保証しない。
- `pipe2(O_CLOEXEC)`はmacOS 27のDarwin runtime symbolを`dlopen`／`dlsym`でprobeし、存在しない場合は`pipe2Unavailable`でfail-closedにする。legacy `pipe`への暗黙fallbackは行わず、`POSIX_SPAWN_CLOEXEC_DEFAULT`と明示的なstandard stream mappingを併用する。このmacOS 27合成実測を、他のOS version／architectureまたは配布runtimeの保証へ一般化しない。
- B2はdirect childの終了を`waitid(... WNOWAIT)`でanchorとして保持し、同一groupへsignalしてからdirect childだけを`waitpid`でreapし、post-reap `kill(-pgid, 0)`の`ESRCH`をboundedに観測する。anchor中の`EPERM`だけをgroup emptyとせずreap後に再検査し、reap後の非`ESRCH` groupへはPGID reuseによる誤signalを避けるため再signalしない。`ESRCH`は観測時点の証拠であり、grandchild reapやparent death cleanupの証明ではない。
- request IDで遅延eventを無効化し、cancel済みrequestのresultを別requestや再生成されたsurfaceへ配送しない。

### 6.4 履歴と診断情報

[TypeScript SDKの公開README](https://github.com/openai/codex/tree/main/sdk/typescript)にはthreadの開始とresumeがある一方、公開されたephemeral／non-persistent thread optionは確認できない。したがって「履歴を保存しない」「zero retention」と表示しない。

- PoCで専用`CODEX_HOME`、cwd、temporary directory、ログ出力をrequest前後にinventoryし、SDK／CLIが作るsession、設定、cache、telemetry等の場所と内容範囲を特定する。
- 正常終了、cancel、crash、kill、電源断ごとにlocal artifactの存続を測定し、cleanup対象と保持期間を固定する。場所、範囲、期間を未確認のまま「localに残らない」と表示しない。
- FUMINIWAのmemory-only契約と、Codex SDK／service側のsession保持、保持期間、学習利用を分けて表示する。後者は確認できた一次資料と実測だけを根拠にする。
- cleanupを実装する場合も、正常終了だけでなくcrash、kill、電源断後を検証し、「痕跡が絶対に残らない」とは表現しない。
- 通常ログへAPI key、prompt、選択本文、応答、diff、絶対path、child environment、生stderrを記録しない。診断はrequest ID、状態、時間、byte数、分類済みerror codeに限定する。

Codex app-serverのexperimental methodや、lifecycleが安定契約になっていない[app-server daemon](https://github.com/openai/codex/tree/main/codex-rs/app-server-daemon)へ直接依存しない。将来SDK内部実装が変わった場合も、FUMINIWAのsidecar protocolとdomain契約を正とし、更新前に隔離、cancel、署名、公証を再検証する。

## 7. OpenRouter adapterの契約

OpenRouterはCodex sidecarの代替経路へ埋め込まず、独立したadapterとして実装する。

利用者向けにはCodexと別の機能画面を作らず、5章のprovider-neutralな校正UIへ同じ機能として接続する。provider／modelの選択、確認済み保持情報、credential設定、typed errorだけをadapter descriptorから差し替え、Editor snapshot、preview、diff、stale、Applyは同じ実装を再利用する。

- nativeなHTTPS clientからdomain requestを変換し、SDK固有型を共有domainへ漏らさない。
- confirmed outboundの`applicationPrompt`と`applicationResponseSchema`をそのままrequestへ写像し、実送信直前のHTTP request captureでhidden instruction／metadataの追加がないことを検証する。
- `model`は利用者がpreviewで確認した単一値だけを送り、代替候補を表す`models`は送らない。上流providerもexact slug／variantを一つに固定し、`provider.order`と`provider.only`はその一項だけ、`provider.allow_fallbacks = false`、`provider.require_parameters = true`とする。指定先が必要parameterまたはstructured outputを扱えなければ送信前に拒否し、別model／providerへroutingしない。
- confirmed budgetの`maximumOutputTokens`を上流`max_tokens`へ設定し、`stream = true`、`response_format.type = json_schema`、`json_schema.strict = true`でsealed `applicationResponseSchema`を写像する。streaming、cancellation、usage reportingをすべて満たし、完了はraw structured outputとusageをdomainのstrict decode境界へ渡す。
- `tools`、server tools、model routing alias／variantを送らない。OpenRouterの全既知plugin IDをreview時のallowlistで固定し、`context-compression`、`response-healing`、`web`等のrequest／responseを変換し得るpluginをrequest単位で明示的に`enabled = false`とする。公式plugin inventoryに未知IDが追加された場合や、account／organizationの「Prevent overrides」で無効化できないpluginがある場合はadapterを利用可能にしない。
- `start`の最初の外部副作用より前にdomain continuationへcancellation handlerを登録する。handler登録より先にsubprocessをlaunchせず、network送信やproducer Taskの実行も始めない。
- API keyはprovider別のKeychain itemへ保存する。
- 初期の個人用契約は`provider.data_collection = deny`と`provider.zdr = true`をrequestへ固定する。exact providerが両制約を満たせなければ送信前またはprovider errorで終了し、制約を黙って緩めない。将来この方針を選択可能にする場合も、実際に送るparameterとrouting結果をテストし、確認できた状態だけをpreviewへ表示する。
- request headerへ`X-OpenRouter-Metadata: enabled`と`X-OpenRouter-Cache: false`を固定し、streamのterminal metadataを必須とする。`requested`、`strategy = direct`、`attempt = 1`、唯一のselected endpoint、model／providerをpreviewで封印した値と照合し、`pipeline`が空であることを確認する。metadata欠損、cache replay、fallback attempt、context compression、guardrail、response healing、server tool等の未知／非空pipeline、または利用した上流providerを確証できない応答は成功扱いにせず、typed failureとして原稿を変更しない。metadataの事後検査は、送信前のplugin無効化と専用account設定の代替にはしない。
- Codex用prompt、session、credential、errorを再利用せず、retryやprovider変更は新しいpreviewと明示確認から始める。

## 8. 保存範囲

| データ | 初期契約 |
| --- | --- |
| API key | provider別にKeychain。取得可能な形でログや設定へ複製しない |
| provider選択・非secret設定 | UI実装PRで保存要否を決める。`.novelpkg`には保存しない |
| exact preview・prompt・選択本文 | request中のmemoryのみ |
| provider response・diff | result表示中のmemoryのみ |
| request state | memoryのみ。アプリ再起動後にresumeしない |
| 診断 | 内容を持たない分類済みmetadataだけ。保持期間はUI実装前に固定する |

requestを閉じる、またはアプリが終了すると、FUMINIWAが保持するpreview／result／diffをすべて破棄する。作品session／対象話が変わる、作品遷移が始まる、または対象Editor surfaceが画面から外れた場合は、未送信previewを直ちに破棄し、実行中requestをcancelして遅延eventを拒否する。同じ話の本文／選択／IME状態だけが変わった場合は、送信中の編集を妨げない方を優先してrequestを別本文へ再束縛せず継続し、完了結果をstaleにする。未送信previewは本文変更通知で無効化し、通知を伴わない選択移動／IME開始も送信クリック時の最終検査で必ず拒否する。すでに完了したresult／diffだけは、現在本文へ適用できないstale表示としてpanelを閉じるまでmemory上の閲覧／Copyを許可してよいが、Applyは必ず無効にする。SDK／provider側の保持はこの表の対象外である。provider／service側の保持期間と学習利用、local SDK／CLI artifactの場所・範囲・保持期間、providerの料金単位とrequest上限は、Experimentalでは確認済み値と未保証を分けて送信前に表示し、公開Releaseでは一次資料と実測による根拠を固定する。価格戦略や契約判断へ拡張せず技術表示の完成条件として扱う。

## 9. PR分割と技術Gate

1. **契約 + 純粋domain**: D-043、本書、provider-neutralなdraft → instruction ID／単一`applicationPrompt`／response schema IDとexact schemaを持つpreview → provider／purpose／budget／input countとともに`AIApplicationPayload`へ封印したone-shot confirmed outbound、domain所有executor、raw structured outputのstrict decode、provider descriptor、domain budget、result／error、event stream protocol、fake、決定論的契約テストだけ。local identity、stale判定、実通信、process、UI、package変更なし。
2. **Editor bridge（完了）**: EditorKitのopaque selection transaction、surface／本文／選択revision、UTF-16 range／exact source、one-shot／1 Undo適用と、document session／episode／source digestを保持するApp local contextを実装した。送信前／適用前stale判定をfake providerで統合テストし、local identityをconfirmed outboundへ混ぜない。
3. **共有orchestrator + fake UI（完了）**: provider-neutralなrequest state machineと、同一のexact preview、明示確認、cancel、diff、stale、Copy、Apply UIをfake providerで接続した。別app target／scheme `FUMINIWAExperimental`だけに露出し、通常の`FUMINIWA` targetから`NovelAI`、Experimental source、compile flagを生成project監査で除外する。実sidecar追加後はArchive inventoryも再検証する。
4. **Codex sidecar protocol（完了）**: content-free attestation、固定framing、上限、typed event、cancel、重複terminal拒否をmockで検証し、実instruction／schemaと合成本文を使うNode／Swift共通fixtureを一致させた(D-047)。実SDK／CLI、credential、network、process起動は含まない。
5. **Manifest primitive + exact SDK capture（B1完了）**: canonical deployment manifest v1のNode builder／verifierを合成treeで固定し、SDK／CLI package 0.147.0をexact pinして合成CLIだけでSDK argv／stdin／schema／environment／usage／cancel／errorをcaptureした。Node 22.23.1と26.4.0のUnicode出力差も固定した。packager、native verifier、実CLI、process supervisor、networkは含まず、exact Node allowlistも未決定のため実送信はNO-GOのままとする。
6. **Darwin native supervisor（B2完了）**: `posix_spawn`／new process group、3 pipe同時処理、stdin／stdout／stderr cap、first-wins cancel／timeout／failure、TERM→KILL、`waitid(WNOWAIT)` anchor、direct child `waitpid`、post-reap `ESRCH`を合成helperで固定した(D-048)。macOS 27では`pipe2` runtime symbolをprobeし、stderr内容を保持しない。実SDK／CLI、network、credential、manifest verifier、OS sandbox、parent death後の回収は含まない。
7. **Codex Experimental isolation feasibility**: allowlist packager／native manifest verifier、exact Node runtime、監査済みlauncherとparent-death境界を追加し、SDK内部framing、request専用empty cwd + `skipGitRepoCheck: true`／`CODEX_HOME`、environment allowlist、OS-level file isolation、memory／CPU／process limit、local artifactの場所・範囲・期間を合成入力から順に実証する。両architecture、署名、公証はこの段階の前提にしない。
8. **Codex Experimental adapter**: sidecar fixed protocol、Keychain one-shot credential pipe、typed error、利用可能なupstream parameter、wire event／process resource limit、実送信直前capture、redacted diagnosticsをdomainと共有UIへ接続する。
9. **OpenRouter adapter**: native HTTPS、provider別Keychain、request capture、routing固定、upstream token capをCodexとは独立して実装し、同じUIへ登録する。自動fallbackなしを双方向のfailure testで固定する。
10. **公開Release Gate**: bundled runtime／hash、arm64／x86_64、nested signing、公証、clean Mac QAを完了し、公開AIを有効化するDecisionを別途承認する。それまでは通常ReleaseへAI target／resource／UIを含めない。

D-046により個人用Experimental AIをPackage Validator GateとExternal Change / Conflict Gateに先行できる。一方、両Gateは公開Releaseの優先事項として維持し、Experimentalで通った機能、UI、実通信をそのまま公開可能とは表現しない。

## 10. 最低受け入れ条件

- fake providerでpreviewしたprovider／purpose／instruction ID／`applicationPrompt`／response schema ID／exact schema／budget／input countとsealed confirmed payloadが完全一致し、local session／surface／range／pathを含まないことを決定論的に検証できる
- 同じconfirmationのcopy／並行実行ではprovider実行権が高々1回だけ取得され、2件目以降は送信前にtyped failureとなる。executor呼出し前／descriptor取得中のcancelとtimeoutでは`start`を呼ばず、stream破棄が先行した場合は`start`またはその最初の外部副作用を拒否する
- 具体adapterは実送信直前のSDK／HTTP requestをcaptureし、sealed prompt／schemaを再構築／追記せず、hidden instruction／metadataを追加しない。上流`maximumOutputTokens`を提供するadapterはconfirmed budgetの設定を検証し、提供しないCodex Experimentalは未保証表示と公開Release blockerを検証する
- provider descriptorがstreaming／cancellation／usage reportingのいずれかを欠けば送信前に拒否される。完了`outputTokens`は必須かつ非負、`inputTokens`は省略可能だが存在時は非負であり、raw structured outputのschema外key／欠損／型違いは`AIResult`へ変換されない
- domainのapp-provided input／raw response／delta／decoded resultの文字・UTF-8 byte上限、wall timeout、usage検査と、adapterの利用可能なupstream token／wire event／process limitを別々のfailure testで再現できる。upstream capがない場合はその欠如をlocal limitで置き換えない
- preview後の1文字変更、作品切替、話切替、surface再生成、dismantleで送信または適用が拒否される
- success、failure、timeout、cancel、遅延完了のいずれでも本文と`.novelpkg`が暗黙に変わらない
- 明示適用だけが対象範囲を1回置換し、1回のUndoで原文へ戻る
- provider failureで別providerへの通信が発生しない
- OpenRouterは単一model／provider、`allow_fallbacks = false`、`require_parameters = true`、strict schema、既知plugin無効化、routing metadata必須をwire captureで固定し、attempt 1以外、非空／未知pipeline、metadata欠損では結果を適用しない
- CodexとOpenRouterが同じEditor snapshot／preview／diff／stale／Apply実装を通り、providerを変えても本文適用ロジックが分岐しない
- prompt、本文、response、API key、pathがログと永続設定へ残らない
- Experimental buildはSDK／CLI／Nodeの実行version、path、hashとlockfile／package integrityのdriftを送信前に拒否し、専用cwd／`CODEX_HOME`、file-read拒否、process tree回収を実機で再現できる
- process lifecycleの受け入れ証拠は、direct childのreap、同一group descendantへのsignalとpost-reap `ESRCH`観測、group脱出拒否、parent death後の回収を分けて記録する。合成supervisor testだけでgrandchild reapまたは一般的なorphan-freeを宣言しない
- 通常ReleaseのArchiveにAI menu／shortcut／設定、Codex／OpenRouter target、Node／CLI／sidecar artifactが存在せず、network／process起動経路へ到達できない
- Codex sidecarを出荷する場合は6章の全Gateをarm64／x86_64、Archive済みnotarized appで再現できる
- provider／service側の保持期間／学習利用、local SDK／CLI artifactの場所・範囲・保持期間を未確認のまま「履歴なし」「学習なし」「zero retention」「localに残らない」と表示しない
- providerの料金単位とrequest上限の根拠、usageが事後報告で費用capそのものではないことを送信前表示で区別できる

## 11. 参照する一次資料

- [OpenAI Codex TypeScript SDK README](https://github.com/openai/codex/tree/main/sdk/typescript) — Node要件、CLI spawn、thread API、environment指定
- [Codex TypeScript SDK package](https://www.npmjs.com/package/@openai/codex-sdk) — 採用時の公開versionとintegrity確認先
- [Codex app-server README](https://github.com/openai/codex/tree/main/codex-rs/app-server) — stable／experimental API境界
- [Codex app-server daemon README](https://github.com/openai/codex/tree/main/codex-rs/app-server-daemon) — daemonのexperimental lifecycle
- [OpenRouter Provider Routing](https://openrouter.ai/docs/guides/routing/provider-selection) — provider指定とfallback制御
- [OpenRouter Structured Outputs](https://openrouter.ai/docs/guides/features/structured-outputs) — `json_schema`、strict mode、parameter対応providerの要求
- [OpenRouter Router Metadata](https://openrouter.ai/docs/guides/features/router-metadata) — 実routing、attempt、pipeline変換のopt-in監査情報
- [OpenRouter Plugins](https://openrouter.ai/docs/guides/features/plugins/overview) — request／responseを変換するpluginとaccount既定値のoverride
- [OpenRouter Message Transforms](https://openrouter.ai/docs/guides/features/message-transforms) — 小context endpointでのcontext compression既定動作と明示無効化
- [OpenRouter Response Caching](https://openrouter.ai/docs/guides/features/response-caching) — request単位のcache無効化header
- [OpenRouter Privacy Parameters](https://openrouter.ai/docs/guides/features/zdr) — request-levelのdata policyを採用する場合の確認先
