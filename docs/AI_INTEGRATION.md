# AI統合 技術契約

**状態: D-075でprovider／fake UI／sidecarの実装・fixture・testを削除。以下はB4-Dまでの研究を残す履歴・再設計条件であり、現行の実装・build target・production catalogではない / B4-E以降は最新stable SDK／APIの明示再評価まで延期 / 通常版の現行AI支援はprovider非依存のclipboard prompt copy**

本書は、ふみにわ（FUMINIWA）が将来provider統合を再開するときの実装境界と安全条件、およびB4-Dまでに固定した研究成果を定める。個別判断は[DECISIONS.md](DECISIONS.md)のD-040 / D-043 / D-046〜D-054、現行のAI支援は[CLIPBOARD_AI_ASSIST.md](CLIPBOARD_AI_ASSIST.md)、実装順は[DESIGN.md](DESIGN.md)、公開Releaseの技術Gateは[COMMERCIALIZATION_IMPLEMENTATION.md](COMMERCIALIZATION_IMPLEMENTATION.md)を正とする。

この契約を文書化したことや純粋domainを追加したことは、AI機能、Codex接続、OpenRouter接続、履歴非保持、配布可能性の完成を意味しない。

## 0. 現在の判断

D-075により、Codex／OpenRouterの実provider統合、B4-E以降、network、credential、実原稿送信は実装ロードマップから外し、B1〜B4-Dのコード、fixture、testも削除した。本書に残る安全契約と研究記録は将来の再設計条件であり、現行のproduction runtime、adapter、approval entry、Experimental targetを意味しない。再開時は最新stable SDK／APIを明示的に再評価する。

通常版`FUMINIWA`の現行AI支援は、校正／アドバイス×本文選択／話／章のplain text promptをsystem clipboardへ明示コピーする非通信機能である。provider、network、API key、subprocess、`NovelAI`、本書のconfirmed outbound／response／Apply境界へ依存しない。system clipboardへ出た内容はFUMINIWAのmemory-only境界の外にあり、他アプリ、clipboard manager、Universal Clipboard等から読まれ得る。詳細は[CLIPBOARD_AI_ASSIST.md](CLIPBOARD_AI_ASSIST.md)を正とする。

B4-Dまでの実装結果、commit、検証値、未達Gate、再評価条件は[CODEX_SDK_FEASIBILITY_REPORT_2026-08-09.md](CODEX_SDK_FEASIBILITY_REPORT_2026-08-09.md)へ日付固定で記録する。以下のprovider契約は休眠中だが、再開時に安全条件を省略しないため保持する。

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
12. **個人用Experimentalと公開Releaseをbuild graphで分ける（履歴）。** 旧実装では、実処理と安全条件を満たすAI UIを別app target／scheme `FUMINIWAExperimental`で先行する境界を定めていた。D-075でtarget／scheme／sourceを削除したため、将来再開時はこの境界をそのまま復活させず、新Decisionでbuild graphと保存境界を再設計する。

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

純粋domain PRで実装した範囲は、providerとUIから独立した旧`NovelAI`のprovider-neutral outbound契約だった。D-075でtarget／公開API／testを削除したため、これは将来APIの根拠ではなく研究履歴として読む。

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

provider統合を明示的に再開する場合の候補順は次のとおりとする。D-054により現在はいずれも延期中であり、これは現行task、自動fallback順、または旧versionの採用承認ではない。

1. **Codex SDK adapter候補**: 再評価時の公式stable境界が安全条件を満たす場合の第一候補。旧0.147.0／Node sidecar構成を自動採用せず、nativeまたはより小さい公式境界も含めて再設計する。
2. **OpenRouter adapter候補**: Codex adapterと別target／別具象型で実装し、provider-neutral domain protocolだけを共有する。Codex再開の有無から自動的に着手しない。

利用者が選んだadapterだけを1 requestに使う。Codexが利用不能でもOpenRouterを呼ばず、OpenRouter内でもmodel/provider routingのfallbackを無効にしてfail-closedにする。providerを変える場合は、送信先、model、保持期間／学習利用、料金単位／request上限の確認済み表示を更新し、exact previewから明示確認を取り直す。

App側はprovider-neutralな`AIProofreadingOperation`相当のorchestratorを一つだけ持ち、Editor snapshotとlocal identity、domain request、表示状態を結合する。UIはproviderごとの画面を作らず、provider選択とprovider固有の確認情報だけを差し替える。Codexのprocess状態やOpenRouterのHTTP response型をSwiftUIへ渡さず、どちらも同じtyped event／errorへ写像する。

## 6. Codex Node sidecarのExperimental／公開Gate

公式のCodex TypeScript SDKはNode.js向けであり、Swift-native SDKではない。[公式README](https://github.com/openai/codex/tree/main/sdk/typescript)はSDKがCodex CLIをspawnし、JSONLで通信する構成とNode.js 18以降を示している。FUMINIWAではSwiftからSDKやCLIを直接呼ぶのではなく、固定protocolを持つNode sidecarを候補とし、公開Releaseではそのruntimeとsidecarをbundleして署名する。

Swift／Node間のwire形式とstate machineは[`Sidecars/Codex/PROTOCOL.md`](../Sidecars/Codex/PROTOCOL.md)を正とする(D-047)。本文を含まない`hello`／`ready`でruntime identityを検査してからだけ`start`を許可し、valid start後は`started`と単一terminalを返す。v1はtoken deltaを捏造せず、Codex結果本文は完了後だけ共有UIへ渡す。protocol mockの成功を実SDK接続、隔離、orphanなしの証明として扱わない。

 canonical deployment manifest v1とB3 packager／verifier境界の正は[`Sidecars/Codex/MANIFEST.md`](../Sidecars/Codex/MANIFEST.md)とする(D-049)。これはD-075で実装を削除する前の研究記録であり、現行target／runtime／catalogへ接続されていない。

2026-08-09時点の調査baselineは公式npmのstable（非alpha）`0.147.0`である。Checkpoint B1で`@openai/codex-sdk` `0.147.0`と対応CLI packageをlockfileへexact pinし、実通信しない合成CLIだけでargv／stdin／schema temporary file／environment／usage／cancel／errorをcaptureした。これは恒久採用versionではなく、provider実装／更新PRごとに公式公開物を再確認し、その時点でreviewしたstable non-alphaをexact pinする。semver range（`^0.147.0`等）は使わず、更新ごとにprotocol capture、tool surface、artifact、cancel、sandbox Gateを再実行する。

Darwin native process supervisorの正は[`Sidecars/Codex/SUPERVISOR.md`](../Sidecars/Codex/SUPERVISOR.md)とする(D-048)。Checkpoint B2では、canonicalなabsolute executable／cwdと明示environmentを`posix_spawn`し、childを新process group leaderにするExperimental-only primitiveを、合成shell helperだけで検証した。stdin／stdoutは512 KiB、stderrは16 KiBを上限とし、stderr内容をresultへ保持しない。timeout／cancel／cap failureはfirst-winsでclaimし、同一groupへTERM→KILL、direct childだけを`waitpid`でreap、reap後の`ESRCH`をboundedに観測する。B3 verifierは後から独立追加され、supervisorのpath-based spawnとはまだ結合していない。実SDK／CLI、network、credential、OS-level sandboxは使っておらず、実送信はNO-GOのままである。

Checkpoint B3のpackager成功値は`candidateRootDigest`であってproduction approvalではなく、root内self manifestもauthorityではない。destination作成後に失敗したrootは`partial_destination_retained`として利用不能のまま残し、自動再利用／継続／再帰cleanupをしない。呼出側がidentityを確認して手動で隔離・削除し、再生成は別の新規empty destination pathで行う。Node pathname APIとSwiftの複数回fingerprint検査は通常raceを狭めるが、same-userによるancestor／root swapや検証直後の置換を閉じない。

### B4 approvalとinventory role

Checkpoint B4-Aは、`FUMINIWAExperimental` native hostにproduction approvalのcompile-time契約を実装した(D-050)。`CodexRuntimeApprovalPolicy`はそのcanonical／validated shapeであり、それ自体はapproval authorityではない。`CodexRuntimeApprovalProposal`もreview用の非authority値で、private initializerの`CodexApprovedRuntimeIdentity`を生成できるproduction approval authorityはnested `ProductionCatalog`だけである。catalogは空なので、承認済みcandidate／Node／SDK／CLI、lookup成功、launch capabilityは0件である。B3 candidate／self manifest、proposal、packager／verifierの観測値、content-free `ready`、B4-BのSHA-256／Mach-O／requested architecture別CDHash／署名observation、B4-C suspended-process observation、local probeをcatalogへ自動登録しない。policy generationは永続的なrevocationやanti-rollbackではなく、旧app／旧catalogへのdowngrade防止を実装済みとは表現しない。

deployment candidateはB3 canonical manifestへ含めた全file／directoryの集合であり、それ自体はapproval inventoryではない。approval inventoryは実装と同じroleを分離する。

- `evaluatedSource`: Nodeがentry、ESM／CJS等として実際に評価してよいsource
- `resolutionMetadata`: package／module resolutionを決めるmetadata
- `executable`: Node、CLI、broker／helper等の実行物
- `conditional`: dynamic import、lazy branch、native addon、library、runtime data等、条件付きでload／exec／readされ得るartifact
- `provenance`: lockfile、license等の由来証拠。runtimeが評価するsourceとは数えない
- `requestData`: prompt、schema、選択本文、response、credential、request ID等。artifact identityへ含めず、content-free Gate完了前にruntimeへ渡さない
- `operatingSystemTrust`: Apple sealed OSのframework／dyld shared cache等、host policyが明示的に信頼する境界。candidateの一部でも、暗黙の無制限allowlistでもない
- `forbidden`: closed inventory外、ambient／global fallback、未承認loader／addon／executable／plugin等、到達時にfail-closedとする対象

content identityは`exactFile`、`boundedRequestData`、`operatingSystemProvided`、`forbidden`を区別する。固定artifactはexact size／digest、可変request dataは専用場所・型・上限、OS提供物は明示trust policyを必要とし、禁止対象はread／evaluate／executeしない。roleとcontent identityの不正な組合せはpolicy validationで拒否する。

Checkpoint B4-Bは`CodexNodeExecutableInspector`を`FUMINIWAExperimental`だけに追加した(D-051)。入力されたabsolute pathのraw UTF-8 bytesをNFC／bounded／controlなしに限定し、`realpath`とopen descriptorの`F_GETPATH`までbyte一致させる。regular file、`nlink == 1`、effective user owner、set-id／sticky／group／world writeなし、owner execute bitありを要求し、最大512 MiBのdescriptor bytesをSHA-256する。thin 64-bit／fat32／fat64 Mach-Oのarchitecture／slice／alignment／overlap／load commandをstrictかつboundedにparseし、requested arm64／x86_64を含まないcontainerは拒否する。

code signatureはrequested architectureを`SecStaticCodeCreateWithPathAndAttributes`の`kSecCodeAttributeArchitecture`へ渡し、Security frameworkのstrict／all-architectures／no-network検証とrequested sliceの20-byte CDHashを観測する。universal Mach-Oとarchitecture別CDHashもobservationに留まり、approvalではない。valid／unsigned／invalid／unavailableのいずれもobservationに封印するが、invalid署名を承認する意味ではない。open後、hash／Mach-O後、signature後にdevice／inode／mode／owner／size／timestamp／flagsとcanonical path／`F_GETPATH`を再検査するが、return後のsame-user swapを防ぐimmutable bindingではない。observationはpath／FD／process handle／launch capabilityを返さず、Node versionやactual child identityも証明しない。

B4-Aに加え、B4-Bもprocess、SDK／CLI import／execution、provider、network、credential、実原稿を一切使わず、通常`FUMINIWA` targetを変更しない。B4-B observationはpath／FD／process handle／launch capabilityを返さず、invalid／unsigned／unavailable signatureも非authority観測に留め、production catalogを空のまま維持する。B4-Cは別のprobe-only primitiveとしてactual childをsuspended起動・照合・kill／direct reapするが、observationをauthority／capabilityへ昇格させずcatalogを空に維持する。B4-Dはさらに別のExperimental-only／mock-only abstract transportとして、content-free `hello` → isolated exact `ready` → sealed `start` → `started` → single terminal → EOFのsequencingとcancellation／cleanupを合成で固定した。具体production channel／factory／callsite、process／Node／SDK／CLI／network／key／実原稿は0件で、B4-C childをresumeまたはtransportへ変換していない。B4-E closed execution closure／native broker／helperとapproval／identity／OS-level read／exec隔離は未実装のままD-054で延期した。最新stable SDK／APIを別Decisionで再評価し、残るD-043／D-046 Gateを完了するまで`codex_sdk`と実送信はNO-GOである。

### B4-C suspended actual-process identity probe

Checkpoint B4-Cは`FUMINIWAExperimental`限定の`CodexSuspendedProcessIdentityInspector`を追加した(D-052)。canonical absolute pathを事前検査し、exact pathだけのargv、empty environment、cwd `/private/var/empty`、stdin／stdout／stderr `/dev/null`、新PGID、空signal mask／default disposition、requested architectureのbinprefで`POSIX_SPAWN_START_SUSPENDED`起動する。caller-supplied architecture／exact lowercase 20-byte CDHashは照合用のnon-authority assertionであり、approvalではない。

actual PIDはPID／direct PPID／PIDと同じPGID／effective・real・saved UID／GID／開始時刻／executable path／`SSTOP`／architectureを前後で照合し、actual identity観測自体も2回一致させる。dynamic PID guestの`SecCode`をno-network exact CDHash requirementで検査し、dynamic valid status、20-byte CDHash、pathを照合し、ad-hoc／unsigned／invalidを拒否する。成功候補とspawn後の通常failureはどちらも`SIGKILL` + direct `waitpid`で回収し、`SIGCONT`／resume APIを持たない。成功resultはarchitecture／CDHashだけで、PID／path／FD／handle／capabilityを含まず、production catalogは空のままである。

timeout／cancelはphase境界でterminal化しwatchdogがkill／reapを開始するbest-effort lifecycle boundであり、同期Security API、inspection worker、blocking `waitpid`のasync hard return deadlineではない。同じUIDの外部processが`SIGCONT`することを拒否／再stopできず、協調的な合成testのconstructor／`main` marker 0をadversarialな「user code実行0」に一般化しない。`kSecCSMatchGuestRequirementInKernel`は実測環境で成功契約にできず、mapped vnode／in-place mutation、同期Security呼出し中のPID再利用raceも解決済みとしない。

合成ad-hoc helperはconstructor／`main` marker 0のまま拒否・回収され、OS署名helperはidentity一致後にresumeされず回収される。実Node／SDK／CLI、network、credential、実原稿は使わない。Node version、B4-B SHA／approvalとの結合、complete loaded closure、dyld／helper／parent-death、OS-level read／exec隔離は後続Gateである。

### B4-D abstract interactive transport sequencing

Checkpoint B4-Dは`FUMINIWAExperimental`限定・mock runtime限定の`CodexSyntheticInteractiveTransport`を追加した(D-053)。これはprocess transportを開く具象実装ではなく、`CodexSyntheticInteractiveChannelFactory`と`CodexSyntheticInteractiveChannel`のabstract契約に対するsequencing feasibilityである。productionのchannel／factory／composition callsiteは0件で、process／Node／SDK／CLI／provider／network／API key／実原稿を使わない。production catalogは空のまま、B4-C childは一度もresumeされず、B4-D channelへ変換されない。

factoryの`openContentFree()`は引数0で、request／payload／identity／pathを受け取らず、呼び出しごとにfreshな1-request／class-bound channelを返す。open中cancelは`requestOpenCancellation()`のacknowledgementとpending openのjoinを両方待つ。stopが先にlate channelが返った場合は、未claimのfresh channelだけをprocess-wide registryでclaimしてcleanupし、既に別sessionがclaimしたduplicateは所有権を取らずcleanupしない。open-cancel acknowledgement／所有するlate cleanup／channel cleanupのsafety failureは先行terminalより優先する。process-wide weak registryは、同じfactoryを共有する別transportをまたいでlive channel reuseを`hello`前に拒否し、通常open／late returnのどちらでも先行ownerのchannelを破壊せず、cleanup済みchannelをstrong retainしない。

`run` entryでsealed `AIApplicationPayload.budget.timeoutSeconds`だけからrequest全体のabsolute deadlineを固定し、factory openやattestationで延長しない。attestation timeoutは別のcontent-free deadlineで0秒超／30秒以下だけを許可する。transportはexact framed `hello`だけを先に書き、exact request ID／mock runtime identityの`ready` 1 frameとdecoderのexact frame boundaryを要求する。coalesced next event、partial trailing frame、mismatch／extra／EOFは`start` 0件で拒否し、attestation完了後にだけsealed payloadからexact framed `start`を1件書く。

responseは`started` → `completed`または`failed`の単一terminal → EOFを必須とする。provider terminalがrequest deadline前にclaimされるとrequest timerを停止し、その観測時から最大1秒のEOF drainを開始する。duplicate terminal、late event、partial frame、missing EOFはfail-closedで、EOFによりdrainが完了するまでresultを返さない。consumer／explicit cancel、attestation／request／drain timeoutはfirst-winsとし、wire terminal後かつdelivery前のlocal cancelもresultを破棄するが、terminal phaseのためwire cancelは0件のままである。

channelのatomic `requestCancellation(cancelFrame:)`はphaseに応じたoptional cancel frameとpending read／writeのunblockを1回の所有者として処理する。finalizing中のcancelはdelivery破棄だけを記録し、I/Oを追加しない。同じtransportの並行runはopen前に拒否し、settled後のcancelはno-opである。factory／channelの生errorやcontentを上位へ漏らさず、固定したoperation／cleanup errorへredactする。

合成B4-D 5 suites／54 testは54/54、`FUMINIWAExperimental`全体は205/205 passした。これはabstract mock channelのprotocol／race／cleanup／redactionの証拠であり、actual process identity／approval／loader closure／OS containmentと結合した実runtime B4-Dの完了やGOではない。B4-Eは未実装のまま延期し、このB4-D snapshotを[実装レポート](CODEX_SDK_FEASIBILITY_REPORT_2026-08-09.md)へ保存する。

### 6.0 二段階のGate

以下はprovider統合を再開する場合の受け入れGateであり、現在のclipboard prompt支援には適用しない。D-054によりExperimental Gateへ進む実装自体を延期している。

- **個人用Experimental Gate（将来再設計）**: Editor bridgeの誤適用防止、exact SDK／CLI／Node version・実行path・cryptographic hashとlockfile／package integrity、request専用cwd／`CODEX_HOME`、environment allowlist、Keychain、OS-level file-read拒否、本文等を残さない診断、cancel／timeout／終了時のprocess tree回収、local artifact inventory、wire／event／time／process上限を実機で通す。実装を再開する場合は、D-075後に新Decisionで定める専用targetへ接続する。
- **公開Release Gate**: Experimental Gateに加え、runtime／SDK／CLI／sidecarのbundle固定と起動前hash検証、arm64／x86_64、nested signing、Hardened Runtime、Archive、notarization、stapling、Gatekeeper、clean Mac更新検証をすべて通す。通常の`Release`へAIを含める判断は別のDecision更新を必要とする。

個人用Experimentalでは、開発機に明示的に用意したNode／sidecarを使ってよく、universal bundle、署名、公証をUI開発の前提にしない。ただし実行path、version、cryptographic hashとlockfile／package integrityを固定・検査し、ambientなglobal Node／Codex、通常の`~/.codex`、作品repository、親environmentへ暗黙fallbackしない。Experimentalで省略できるのは配布成立の検証だけで、原稿、credential、supply-chain identity、file access、process lifecycleの安全条件ではない。

### 6.1 Supply chainと配布物

- Experimentalでもlockfileを正とし、SDK／transitive dependencyのpackage integrity、CLI／Node／sidecarの採用version、実行path、cryptographic hashを記録する。実行時のversion、path、hashが期待値と異なる場合は送信前に拒否し、別のglobal installへfallbackしない。
- 公開Releaseではnpm installやruntime downloadを利用者環境で行わず、lockfileとvendor済み成果物から再現可能に組み立てる。
- 公開ReleaseではCodex SDK、全transitive dependency、Node runtime、Codex CLI executableのexact versionと公式integrity／cryptographic hashをallowlistで固定し、起動前にも改ざんを検出する。
- 公開ReleaseではNode runtime、sidecar script/bundle、Codex CLI、必要なnative artifactをアプリbundle内の決めた場所にのみ同梱する。
- 公開Releaseではhelperとすべてのnested executable／libraryをDeveloper IDで適切に署名し、Hardened Runtime、Archive、notarization、stapling、Gatekeeper検証をアプリ全体で通す。
- 公開Releaseではarm64とx86_64の各clean Macで、初回起動、実request、cancel、更新後起動を検証する。片方のarchitectureだけの成功でuniversal配布可能としない。
- B3 packagerはarm64の固定21 fileだけを候補rootへコピーし、caller supplied allowlist、x86_64、Node executableを含まない。B4-Aのcompile-time approval契約へ返すdigest／self manifestを自動登録せず、B4-B／B4-C observationとlocal probe identityもapprovalへ昇格させず、empty production catalogを維持する。
- B3 native verifierはexpected digestを独立引数で受け、filesystem mutationをfail-closedにするが、owner-writable treeをimmutableにせず、検証したbytesを後続import／spawnへfdで引き渡さない。B4-Bでexact Node path上の実行物の非実行観測、B4-Cでactual process identityのprobe、B4-Dでabstract mock interactive sequencingまで実証した。完全なloaded artifact inventory、immutable verify-to-use binding、approval／identity／OS read／exec隔離を結合するB4-Eは未実装で、最新stable SDK／APIの明示再評価まで延期する。

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

1〜11はB4-Dまでの完了記録として保持する。12〜16はD-054により現在のbacklogから外し、最新stable SDK／APIの明示再評価後に必要性と順序を決め直す。通常版clipboard prompt支援はこのprovider PR列へ含めず、[CLIPBOARD_AI_ASSIST.md](CLIPBOARD_AI_ASSIST.md)の独立した非通信境界で実装する。

1. **契約 + 純粋domain**: D-043、本書、provider-neutralなdraft → instruction ID／単一`applicationPrompt`／response schema IDとexact schemaを持つpreview → provider／purpose／budget／input countとともに`AIApplicationPayload`へ封印したone-shot confirmed outbound、domain所有executor、raw structured outputのstrict decode、provider descriptor、domain budget、result／error、event stream protocol、fake、決定論的契約テストだけ。local identity、stale判定、実通信、process、UI、package変更なし。
2. **Editor bridge（完了）**: EditorKitのopaque selection transaction、surface／本文／選択revision、UTF-16 range／exact source、one-shot／1 Undo適用と、document session／episode／source digestを保持するApp local contextを実装した。送信前／適用前stale判定をfake providerで統合テストし、local identityをconfirmed outboundへ混ぜない。
3. **共有orchestrator + fake UI（履歴・削除済み）**: provider-neutralなrequest state machineと、同一のexact preview、明示確認、cancel、diff、stale、Copy、Apply UIをfake providerで接続した。D-075でfake UI／`FUMINIWAExperimental`／`NovelAI`を削除したため、将来再開時は旧実装を復活させず、新Decisionと最新APIから再設計する。
4. **Codex sidecar protocol（完了）**: content-free attestation、固定framing、上限、typed event、cancel、重複terminal拒否をmockで検証し、実instruction／schemaと合成本文を使うNode／Swift共通fixtureを一致させた(D-047)。実SDK／CLI、credential、network、process起動は含まない。
5. **Manifest primitive + exact SDK capture（B1完了）**: canonical deployment manifest v1のNode builder／verifierを合成treeで固定し、SDK／CLI package 0.147.0をexact pinして合成CLIだけでSDK argv／stdin／schema／environment／usage／cancel／errorをcaptureした。Node 22.23.1と26.4.0のUnicode出力差も固定した。この段階単独ではpackager、native verifier、process supervisor、networkを含まない。
6. **Darwin native supervisor（B2完了）**: `posix_spawn`／new process group、3 pipe同時処理、stdin／stdout／stderr cap、first-wins cancel／timeout／failure、TERM→KILL、`waitid(WNOWAIT)` anchor、direct child `waitpid`、post-reap `ESRCH`を合成helperで固定した(D-048)。macOS 27では`pipe2` runtime symbolをprobeし、stderr内容を保持しない。実SDK／CLI、network、credential、manifest verifier、OS sandbox、parent death後の回収は含まない。
7. **固定packager + native verifier（B3完了）**: Node packagerでarm64 0.147.0の固定21 fileをreal copyし、source hashからdestination canonical manifestのcandidate digestを作る。Swift Experimental verifierをNode oracleと一致させ、strict filesystem／resource／mutation rejectionを固定した(D-049)。partial rootは保持して手動処理し、既存destinationは変更しない。実SDK／CLI／key／network／原稿は使わず、candidateを実行承認へ昇格しない。
8. **Compile-time approval contract（B4-A完了）**: candidate生成と独立したnative catalog contract、validation、inventory role、空のproduction catalogを固定した(D-050)。承認済みartifactと実行経路は0件で、process／SDK／CLI／network／credential／原稿を使わない。anti-rollbackは未実装である。
9. **Exact Node inspector（B4-B完了）**: catalogを空のまま、canonical raw path／`realpath`／`F_GETPATH`、owner／mode／`nlink`／size／SHA-256、strict thin／fat Mach-O、no-network Security validity／requested architecture別CDHashを最大512 MiBでnative観測する(D-051)。invalid署名やuniversal Mach-Oを含むobservationをapprovalへ昇格させず、path／FD／capabilityを返さず、spawnしない。
10. **Suspended identity probe（B4-C完了）**: 固定argv／empty environment／`/private/var/empty`／null stdio／新PGIDで`START_SUSPENDED` childを作り、actual PIDのprocess identityとdynamic SecCode／no-network exact caller-supplied CDHash／非ad-hocを二重照合する。成功時もresumeせずkill／direct reapし、architecture／CDHashだけの非authority observationを返す(D-052)。
11. **Interactive content Gate（B4-D sequencing完了）**: Experimental-only／mock-onlyのabstract channelでcontent-free open、isolated exact `ready`後のsealed `start`、`started` → terminal → EOF、cancellation／cleanupを固定した。具象process transportとのnative identity結合は未実装で、実runtime B4-DのGOではない。
12. **Closed execution closure（B4-E、延期）**: closed linker／native broker／helperとapproval／actual identity／OS-level read／exec隔離を結合し、evaluated／conditional artifact、CLI、library、runtime dataを閉じ、検証済みbytesと実際のimport／path-based spawnを不可分にする。same-user ancestor／root swapをpathname再検査だけで解決済みとしない。再評価後のSDK境界でなお必要な場合だけ設計する。
13. **Codex Experimental isolation feasibility（延期）**: 監査済みlauncherとparent-death境界、SDK内部framing、request専用empty cwd + `skipGitRepoCheck: true`／`CODEX_HOME`、environment allowlist、OS-level file isolation、memory／CPU／process limit、local artifactの場所・範囲・期間を合成入力から順に実証する。両architecture、署名、公証はこの段階の前提にしない。
14. **Codex Experimental adapter（延期）**: sidecar fixed protocol、Keychain one-shot credential pipe、typed error、利用可能なupstream parameter、wire event／process resource limit、実送信直前capture、redacted diagnosticsをdomainと共有UIへ接続する。
15. **OpenRouter adapter（延期）**: native HTTPS、provider別Keychain、request capture、routing固定、upstream token capをCodexとは独立して実装し、同じUIへ登録する。自動fallbackなしを双方向のfailure testで固定する。
16. **公開Release Gate（provider再開時だけ）**: bundled runtime／hash、arm64／x86_64、nested signing、公証、clean Mac QAを完了し、公開AIを有効化するDecisionを別途承認する。それまでは通常Releaseへprovider target／resource／UIを含めない。

D-046の個人用Experimental先行方針はD-054で延期した。Package Validator GateとExternal Change / Conflict Gateは公開Releaseの優先事項として維持し、B4-DまでのExperimental成果を実通信可能または公開可能とは表現しない。

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
- B3 packagerは固定21 file、exact metadata／SRI、real copy、source hash→destination manifest、既存destination不変、partial root保持を合成testで再現できる。candidate digest／self manifestが実行承認ではなく、partial rootを再利用せず別の新規empty pathで再生成することを型付きerrorで判定できる
- B3 native verifierはNode oracleとcanonical bytes／digest／recordを一致させ、独立expected digest、symlink／hardlink／special file／危険mode／resource超過／mutationを拒否する。これだけでcompile-time allowlist、exact Node、complete loaded inventory、immutable verify-to-useを宣言しない
- B4-Aのproduction catalogが空であり、candidate／self manifest／B4-B observation／local probeからentryが自動生成されず、lookupが常にfail-closedであることを決定論的に検証できる。policy generationだけでanti-rollbackを主張しない
- deployment candidateと、`evaluatedSource`／`resolutionMetadata`／`executable`／`conditional`／`provenance`／`requestData`／`operatingSystemTrust`／`forbidden`のroleが混同されず、`exactFile`／`boundedRequestData`／`operatingSystemProvided`／`forbidden`のcontent identityとの不正な組合せを拒否する。README等のprovenanceをevaluated sourceと数えたり、request dataをartifact digestへ混ぜたりしない
- B4-BのExperimental native inspectorがcanonical raw path／`realpath`／`F_GETPATH`、regular file／owner／mode／`nlink`、512 MiB size／SHA-256、strict thin／fat Mach-O、no-network Security validity／requested architecture別CDHashを非実行で観測し、invalid signatureやuniversal Mach-Oも非authorityに留め、catalogを空に維持する。B4-Cのprobeはactual suspended identity、非ad-hoc dynamic code、success／failureのkill／direct reap、constructor／`main` marker 0を再現する。timeoutはbest-effort lifecycle境界でasync hard return上限ではなく、same-uid外部`SIGCONT`、mapped-vnode／in-place mutation、B4-B SHA／approval結合、Node versionは未達である。B4-Dのabstract mock transportはinteractive `hello`／`ready`／`start`／terminal／EOFを再現するが、実processとの結合はしない。再開時にB4-E相当が必要ならclosed load／execを個別に再現し、専用cwd／`CODEX_HOME`、より広いfile isolation、parent-death後を含むprocess回収も独立Gateで再現する
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
