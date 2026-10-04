# P10a / P10b 認証characterization（2026-10-04）

P10a / P10bだけを実施。認証flow・request ownership・durable account transitionの本体は移設・統合していない。D8のiOSモデルをcoreにする作業はP10c / P10dへ残す。

## 共通シナリオと観測境界

`NovelKit/Tests/NovelWorkspaceTests/Authentication/AccountTransitionConformance.swift`の同じdriverを、test-only `AccountTransitionHost` portのreference fake、`NovelAppTests/AccountTransitionConformanceTests.swift`、`NovelAppIOSTests/AccountTransitionConformanceTests.swift`で実行する。adapterは実際のrestore／Apple／Google／sign-out／transition入口を呼び、SQLiteは`TestRuntimeConfiguration`、同期通信は既存fake remote、認証通信とproviderはfakeを使う。

18シナリオ：launch restore、Apple、Google、sign-out、A→B、token refresh、exchange failure、mid-exchange cancellation、未ログインからのfailure／cancellation、vaultにBが確定した後のexchange failure、IME拒否、旧epochの直接transition／launch restore、Apple credential revoked時のrestore、pending revoke retry、exchange中のsign-out、revoke待機。

IME準備callbackで共有applicationのsuspensionを取得済みのlease数と現在のsessionを記録する。未保存titleを実際のSQLiteから読み戻し、exchange待機中に旧sessionがUIから退役しworkがdurably parkedであることを確認する。account-scoped conflict／catalog cursorの消去、実際のwork taskとAI requestの取消、終了後のlease解放も検査する。refreshはAccountID／fence／server／epochを保持し、世代と取消policyのOS差を検査する。

Macの既存Test compositionはAppleだけnative orchestratorを使うため、Appleのテストはその入口を使用する。production MacのApple browser／iOSのnativeという構成差は`AuthCompositionTests`でも検査する。Googleは両OSで実際の`AuthSessionCoordinator.signInBrowser`へ進み、ブラウザ表示callbackだけを差し替える。外部OAuth・実Keychainの既存ユーザーsession・署名済み実機の受入結果ではない。

## P10cへ渡す差分の全一覧

| シナリオ | macOSの現在の挙動 | iOSの現在の挙動 | 統合時のrisk |
| --- | --- | --- | --- |
| Apple入口の構成 | productionはbrowser。既存Test compositionはnative orchestrator | native。Googleは両OS browser | provider構成を統一するとAppleの認証方式が変わる |
| Apple／Google sign-in、A→B、sessionを復元できるexchange failure／cancellation | IME準備2回（旧scope退役、destination反映） | 追加preflightを含みIME準備3回 | preflightの削除・重複保存の追加が編集境界を変える。どちらも初回準備より先にleaseを取得 |
| 同一scopeのtoken refresh | auth ownerをclaimしgenerationを増やし、work／AI requestを取消。account-scoped UIは保持 | generationを保持し、work／AI requestも継続。UIは保持 | 同じaccountの通常refreshで進行中の処理を不要に退役させる可能性 |
| unsigned exchange failure | signedOutへ戻し、別のoperationMessageで失敗を通知。IME準備1回 | authUIStateをfailedにする。preflightを含みIME準備2回 | 認証画面と通知の意味を落とさない |
| unsigned mid-exchange cancellation | signedOutへ戻す。IME準備1回 | failedの取消表示を残す。IME準備2回 | 利用者の取消を未ログイン表示／失敗表示のどちらにするかを暗黙に変えない |
| A、またはvault確定済みBを復元できるexchange failure | signedInへ復元後もoperationMessageに失敗通知を残す | signedInへの復元で一時的なfailed表示が置き換わり、独立したoperationErrorMessageは残らない | 回復成功後に失敗理由が見えなくなる／重複通知する可能性 |
| exchange待機中のsign-out要求 | authOperationGateで交換終了後までqueueし、その後sign-outする | live request windowがあるため要求を受けずに戻る。交換成功後はBでsignedIn | sign-outの意思が失われる。単なるgate置換では同じ挙動にならない |
| remote revoke待機中のsign-out | callerはrevoke完了をawaitし、remote suspension leaseを保持。interactive countは解放済みでlocal操作可能 | local退役後にcallerとleaseを解放し、別taskでrevoke。local操作可能 | UI完了時機・lease寿命・後続認証要求の順序が変わる |
| offline sign-out後のpending revoke retry | App側に対応するlaunch／foreground retry入口がない | `resumePendingAuthRevoke`で既存journalを再実行。後からvaultへ保存されたBは保持する | revoke残件を落とす、またはretryで新sessionを失効させる可能性 |
| 旧epochの直接transition | nilへ正規化してpark、authUIStateはunavailable、成功Boolはtrue | park、authUIStateはfailed、成功Boolはfalse | Boolだけでresume／回復を判断するとfail-closed後の扱いを誤る |
| 旧epochのlaunch restore | park後にcoordinator.signOutを実行し、旧vault sessionを除去。unavailable | parkしてfailed。旧vault session自体は保持 | cleanup／revoke／次回launchでの再検出を変える。どちらも旧sessionをpublishしない |
| native Apple credential revoked時のlaunch restore | credential-stateのadvisory照合でparkしsignedOut | vault sessionを復元してsignedIn。restoreではcredential-stateを照合しない | advisory provider状態とserver sessionのどちらをrestoreで優先するかが変わる |

同じ挙動も確認した：正常restore／sign-out、failure／cancellation時にAを回復、vault確定後のfailureでBを回復、IME拒否時の旧sessionと原稿保持、旧epochで本文を保持してpark、scope変更時のUI消去／work・AI取消、全シナリオのlease解放。request windowのabandon recoveryの構造自体はiOSに残し、Macのgate／owner／interactive countとの移設は行っていない。

## P10b compositionと互換証拠

`NovelWorkspace.AuthComposition`へsession vault、HTTP transport／configuration、limits、Apple coordinator／native orchestrator、Apple／Google用browser authorizationの生成を集約した。入力はKeychain service、clientPlatform、Apple flow、presentation anchor provider、既存phase observer。Appは既存のnetwork／origin判断と値を渡す。browser coordinatorは従来どおりauthorizationごとに新しく作る。anchor未指定時は従来の各OSのwindow選択をそのまま使う。

| 値 | macOS：変更前→変更後 | iOS：変更前→変更後 |
| --- | --- | --- |
| session Keychain service | `dev.serikayuzuki.fuminiwa.sync` → 同一 | `dev.serikayuzuki.fuminiwa.sync.ios` → 同一 |
| clientPlatform（HTTP／coordinator） | `.macos`（coordinatorは従来default）→ 明示`.macos` | 明示`.ios` → 明示`.ios` |
| clientVersion | `0.1.0` → 同一 | `0.1.0` → 同一 |

`KeychainAuthSessionVault`と`AuthVaultRecord`の実装・serializationに差分はない。session itemの既定accountは引き続き`session`。Apple credential-state vaultも従来どおり`jp.fuminiwa.apple-credential-state`と既定provider configurationを使用する。limitsの全6値は旧両factoryと同一で、compositionテストで確認した。namespace移行や既存itemの読直し・書換えを追加していない。

安全側の選択：OS差は全て維持。Test buildに限りbrowser callback、auth composition、Macのserver namespace overrideを注入できるようにし、固定`test-server`の既存runtimeと実際のauth境界を合わせる。shared controllerのlease集合はinternal readbackだけを許可し、setterはprivateのまま。shared factoryを移設先として境界検査へ登録し、AppのTest buildからの`AuthComposition(...)`呼出しは禁止した（禁止callを置いた一時fixtureでも拒否を確認）。

## 検証結果

`./Scripts/check-changed.py --base main`で開始し、失敗した段階と未実施の後続段階を`--step`で再開。初期のformat／lint／compile／境界検査失敗は修正済み。追加・修正したpackageテストの再確認は同scriptの明示ファイル指定でNovelWorkspaceTestsだけを選び、成功済みの他targetは再実行していない。`check.sh`は未実施（P10終端のorchestrator担当）。

- 成功：SwiftFormat、SwiftLint、D-076、sync target dependencies、test network boundary、AI target separation、sync v2 boundary、Xcode project生成。
- 成功：選択されたpackage 4 targets。NovelWorkspaceUITests 41、NovelAuthTests 63、NovelSyncV2ApplicationTests 221、最終NovelWorkspaceTests 88（fakeの18シナリオを含む）。
- 成功：macOS app。xcresult summaryは210定義成功／4skip、parameter展開後263実行成功、失敗0。共通18シナリオは18/18 Passed。
- 成功：iOS Simulator app。xcresult summaryは154定義成功／3skip、parameter展開後186実行成功、失敗0。共通18シナリオは18/18 Passed。
- 実Keychainの既存ユーザー受入、外部OAuth、署名済み実機、deployment／公開は未実施。既存skipを受入成功へ数えていない。

xcresult：`Test-FUMINIWA-2026.10.04_22-23-11-+0900.xcresult`、`Test-FUMINIWAIOS-2026.10.04_22-23-39-+0900.xcresult`。両bundleのtest treeでも18個のparameter resultを確認した。
