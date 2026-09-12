# Workbench・AI支援・offline保存の実装記録

2026-09-12。土台は`codex/docs-current-guidance-20260912`、作業branchは`codex/workbench-ai-offline-20260912`。開始時のtracked差分はなし。未追跡の`NovelApp 2026-07-16 23-51-50/`は保持した。原稿・実DB・署名設定・生成Xcode projectは変更対象／commit対象にしていない。

利用者指定は週間残高40%を下限とすること。開始時59%、コミット前の最終確認時58%。自動reset・追加購入・別taskへの委任は行っていない。

## 実装したこと

| 依頼 | 実装 |
| --- | --- |
| 伏線下段の余白 | 内側のHSplitViewと子paneを高さ一杯にし、grouped Formの固定的な配置を可変高のメモへ変更。短いpaneでは全体をscrollできる。上段のカードは変更しない |
| 明示ログイン／専用作品一覧 | macOSの独立した「作品一覧」window、toolbarとFileメニューの入口、Cmd+Shift+L。List選択→開く／primary action。Apple認証を一覧・設定から明示実行。新規／取り込み後は執筆windowへ移り、一覧windowだけの起動でもbootstrapする。編集中の作品のopenは既存gateを使用。sign-in失敗も操作messageへ表示 |
| offline保存・同期 | Mac保存中の追加入力が保存済みに紛れるrevision競合を修正。両OSのautosaveが自身のTaskをcancelしないよう修正。NWPathMonitorの接続回復で既存outboxをwake。iOS明示同期の前にlocal saveとsession/account再検査 |
| iOS現行対応 | 執筆補助、選択／話／章promptコピー、AI inspectorと設定をlive v2画面へ接続。履歴のID入力を日時選択と確認dialogへ変更。diagnostic認証ログを分割して800行Gateを解消。最低対応OSは17を維持 |
| AI右panel | macOS右inspectorとiOS適応inspector、校正／感想／アドバイス、現在の1話preview、明示送信、取消、一時回答。API URL・モデル・用途別prompt・端末限定Keychainキー設定。D-089と[技術契約](WRITING_ASSISTANT.md) |

設定やAI回答は通常の作品・同期データへ混ぜない。API結果の原稿へのApply、会話の永続化、本文の自動送信は含まない。旧provider研究コードを復活させていない。

## 今回の検証

保存・認証・共有sourceを含むため**重たい検証**を選択した。全体scriptが環境で停止した後、残るSwift／App検証を個別に実行した。

| 検証 | 結果 |
| --- | --- |
| `Scripts/check.sh` | **失敗**。Pythonの60 vectors、Swiftの6 conformance tests成功後、`cargo: No such file or directory`で停止。Rust／PostgreSQLは未実施 |
| `swift test --package-path NovelKit` | **成功**。652 tests、exit 0。Mac EditorKitのIME・Undo・capture、v2のoffline・再起動・account隔離等を含む |
| macOS App全体 | **成功**。139 tests／29 suites。後続のUI・auth対象8 tests、最終startup／window対象17 tests、AI追加5 testsも成功 |
| iOS App全体 | **成功**。iPhone 17 Simulator、109 tests／21 suites。後続のAI追加5 testsも成功 |
| iOS EditorKit | **成功**。76 tests／7 suites。Simulator上のIME・Undo・selection等 |
| macOS通常build | **成功**。署名なし |
| iOS通常build | **成功**。generic iOS実機向け／Simulator、署名なし。Xcode 27.0（27A5194q） |
| 構造／依存／test composition／AI・sync境界 | **成功**。iOS認証sourceの800行超過は診断の分離で解消 |
| 変更したSwiftのformat／lint | **成功**。既存baselineを拡張して抑制していない |
| 全repo format／lint | **失敗**。未変更`NovelKit/Sources/NovelAuth/AuthDomain+AppleRecovery.swift`のextensionAccessControl、未変更`NovelAppIOSTests/IOSSnapshotSyncV2AccountTransitionP1Tests.swift:335`のtype_body_length（357行）。今回は無関係な整形・test分割を行っていない |
| 伏線のnative layout | **成功**。高さ540ptの下段でメモのnative scroll viewportが250pt超になることを確認。小さなFormのまま固定されない |
| 全面的な外観・操作の手動QA | **未実施**。fixtureのview描画は実行したが、cacheDisplay画像はnative button／materialの合成が不完全。画面撮影も環境で失敗したため、色・可読性・クリック受入の証拠には使わない |
| LAN疎通 | unauthenticated GET `/v2/capabilities`にTLS経由HTTP 422（必要header/authなし）を確認したのみ。認証・同期成功の証拠ではない |
| 実API送信／署名済みAppleログイン／Mac-iPhone双方向同期 | **未実施**。利用者原稿や実APIキーを開発テストから送信していない |

ローカルログは`/tmp/fuminiwa-*.log`、Xcode詳細はDerivedData内のxcresult。tmp／DerivedDataは永続成果物ではないため、上表を引き継ぎの要約とする。

## 次に行うこと

1. Rust toolchainのある開発環境で`Scripts/conformance-v2.sh`のRust testsを実行。既存の全repo lint違反を別の限定変更で解消すれば全体scriptを通せる。実DBは専用test DBを明示し、production DBを流用しない。
2. 署名済みMac／iPhoneで、作品一覧→作品open、新規作成、Appleログイン、失敗後再試行を確認する。ログイン前に作った作品は自動で別accountへbindせず、既存「このアカウントへ追加して同期」を使う。
3. 特に8月18日の「認証済み新規作品が端末のみ」の実機事象は、local checkpoint→binding→createWork/upload/register/publish→remote head read-backまで再現する。今回のsave修正がこの過去事象の原因だったとは断定しない。
4. 両端末でWi-Fi切断中に作成・編集・終了・再起動、復帰後のoutbox再開、相互の最新本文、同時編集の3択競合、履歴復元を受け入れる。接続監視はwake hintであり、サーバーの稼働や認証を保証しない。
5. 利用者が設定したAPIキー／モデルで合成本文を送信。HTTP失敗、取消、作品／話切替時の失効、iPhoneの入力設定、iPadのinspector幅を確認。Keychainはendpoint別なので送信先を変えた場合はその送信先用キーを保存する。
6. Light／Dark、狭幅、拡大文字、VoiceOver、toolbar削除後のメニュー、実IME・Undoを手動確認。iOSの共通chrome全体（現状`iosWorkChrome`はno-op）と全機能の配布品質は追加受入が必要。

GitHub push／PR／merge、インストール先アプリの置換、デプロイ、公開は未実施。今回のbranchを保って再開し、古いmainへ差し替えない。
