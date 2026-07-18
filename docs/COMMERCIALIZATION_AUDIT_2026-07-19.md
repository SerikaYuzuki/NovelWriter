# NovelWriter 商業化総合監査レポート

- 監査日: 2026-07-19
- 対象: macOS版の現行仕様・実装・保存形式・配布物・UI/UX・商品戦略・運用
- 結論: **優れた技術試作ではあるが、現状のまま有償販売できる製品ではない**
- 本文中の優先度: `P0` = 課金・一般配布前に必須、`P1` = 有償ベータ〜1.0必須、`P2` = 差別化と定着、`P3` = 検証後の拡張
- この文書は監査と提案のみを行い、実装変更は含まない

## 読み方

- 最短で判断する: [0. 先に結論](#0-先に結論) → [4. P0問題](#4-商業化を止めるp0問題) → [17. ロードマップ](#17-推奨ロードマップ) → [20. 最終提言](#20-最終提言)
- 商品思想とUX: [3. 思想](#3-そもそもの思想からの精査) → [5〜9. 執筆・構成・推敲・出力](#5-基本執筆体験の監査) → [16. 細部](#16-神は細部に宿る設計)
- 技術・安全・AI: [10. 保存とsecurity](#10-データ安全性保存形式セキュリティ) → [11. AI](#11-ai支援の製品プライバシー設計) → [12. 品質](#12-アクセシビリティ性能品質保証)
- 事業化: [13. 市場](#13-市場名称競合差別化) → [14. 価格・流通](#14-価格試用課金流通) → [15. 法務・運用](#15-法務プライバシーサポート運用)
- 実装計画へ転記する: [付録A 実行バックログ](#付録a-実行バックログ)
- 根拠を確認する: [付録B ローカル根拠](#付録b-主なローカル根拠) / [付録C 公開資料](#付録c-参照した主な公開資料)

## 0. 先に結論

NovelWriterには、商品になり得る強い核がある。macOSネイティブ、TextKit 2と日本語IMEを尊重した本文編集、章・話・人物・プロット・伏線・資料・世界観を一つのローカル作品に保持する構造、TXT / Markdown / EPUBへの書き出し、`.novelpkg`という可搬境界は、いずれも良い出発点である。依存方向、本文所有権、保存直列化、Undo、エクスポート分離を設計文書とテストで守っている点も、個人開発の試作品としてはかなり丁寧である。

しかし商業化では、「機能がある」より先に「原稿を失わない」「開けない時に何が起きたか分かる」「正しく配布・更新できる」「他製品と混同されない」「困った時に助けがある」が問われる。現状はこの信頼層に重大な穴がある。

最重要判断は次の8点である。

1. **名称を商業化前に再検討する。** 既に長年運営される無料OSSの小説執筆アプリ [`novelWriter`](https://novelwriter.io/) が存在する。侵害の有無は別として、検索、口コミ、問い合わせ、レビュー、ドメイン、商標の混同リスクが高すぎる。
2. **「日本語小説を書く人全般」を狙わない。** 当面は「Mac中心・横書き長編/Web小説・一人執筆・データを手元に置きたい作者」に絞る。縦書き、DOCX/PDF、モバイル、共同編集がない状態で、文芸公募・商業出版・同人組版まで同時に約束しない。
3. **AIより先に信頼性と発売基盤を完成させる。** 現ロードマップの「Phase 6 AI → Phase 6.5 PDF」は商品優先度として逆転している。読込失敗の回復、形式検証、バックアップ、検索置換、入出力、署名・公証・更新、ヘルプとサポートが先である。
4. **起動・読込・保存のP0欠陥を解消する。** 編集可能なプレースホルダーを表示してから非同期で作品を差し替える起動、前回作品の読込失敗をコンソールだけに出して新規作品へ落とす挙動、不正UTF-8を空本文として扱う読込は、有償製品では許容できない。
5. **`.novelpkg`を「ただの実装」から「作者の所有権を守る商品価値」に昇格させる。** 仕様、検証、復旧、バックアップ、未知項目保持、OS間round-tripを実証し、いつでもTXT/Markdown等へ救出できることを約束する。ただし現時点で「標準形式」「完全互換」とは呼ばない。
6. **AIは主役ではなく、完全に消せる編集支援にする。** 原稿送信の範囲・送信先・費用・保持方針を毎回説明し、根拠箇所と差分を示す。自動上書きをしない。「AIを一度も使っていない作品」を確認できること自体が差別化になる。
7. **製品思想を「多機能な小説IDE」から「静かな日本語長編の仕事机」へ寄せる。** 構造管理は強いが、執筆中は存在感を消す。必要な時だけ奥行きが現れるprogressive disclosureを全UIの基準にする。
8. **直販の有償ベータから始める。** Developer ID署名・公証済みDMG、安全な自動更新、試用、返金、サポート、規約を揃える。Mac App StoreはSandbox対応という別プロジェクトになるため、初期チャネルにはしない。

推奨する一文のポジショニングは次である。

> 原稿を手元に置く、日本語長編の仕事机。構成・設定・本文が離れず、AIを使うかも作者自身が決められる。

## 1. 監査範囲と確度

### 1.1 確認したもの

- `docs/DESIGN.md`、`docs/DECISIONS.md`、`docs/CROSS_PLATFORM.md`、`docs/STYLE.md`、各Phase記録
- `NovelApp`、`NovelKit`、テスト、`project.yml`、`Scripts/check.sh`
- 現在のローカルCI一式
- 直近に生成された `.app` の署名、entitlements、Info.plist、アーキテクチャ、Gatekeeper判定
- GitHub上の公開リポジトリ、タグ、Release、ライセンス表示
- 2026-07-19時点の国内外競合、価格、Apple配布要件、AIプライバシー、国内通信販売の公開情報

`./Scripts/check.sh` は完走し、Swift Packageテスト、macOSアプリテスト、iOS向けコンパイル確認、macOSビルドは成功した。一方、SwiftLintにはファイル長と型長の警告が各1件残っており、文書にある「警告ゼロ」とは一致していない。

### 1.2 UI監査の制約

現行コード、UI構造、アクセシビリティ属性、直近のパッケージ版スモーク記録は確認した。ただし監査時点のMacがロックされており、現在ビルドを操作しながら行うピクセル単位の目視確認はできなかった。このため、色の見え方、実際のフォーカス移動、VoiceOver読み上げ、狭いウィンドウでの崩れ、操作感の最終評価は暫定である。有償ベータ前に、実機で別途UI監査を行う必要がある。

### 1.3 事実・推論・提案の区別

- コードや配布物から確認できたものは「現状」として記す。
- 競合の利用者数や機能は各社・ストアの公開表示であり、第三者監査値ではない場合がある。
- 価格、ターゲット、ロードマップは市場事実ではなく検証すべき仮説である。
- 法務項目は論点整理であり、法的助言ではない。課金前に弁護士・弁理士・税務の専門家へ確認する。

## 2. 現状評価

### 2.1 商品に残すべき強み

| 強み | なぜ価値があるか | 商品化での伸ばし方 |
|---|---|---|
| macOSネイティブ + `NSTextView` / TextKit 2 | 日本語IME、Undo、選択、キーボード操作でWebアプリより自然にできる余地がある | 実IME・VoiceOver・長文で品質を証明し、「Macらしい」を機能ではなく操作の一貫性で示す |
| 本文の所有権を`NSTextView`側に置く設計 | IME確定前の破壊やカーソル飛びを避ける基礎になる | この原則をAI差分、校正、検索置換にも適用する |
| 章・話・人物・プロット・伏線・世界観・資料の統合 | 長編で散らばる情報を本文と同じ作品単位に置ける | すべてを常時見せず、本文から根拠箇所へ往復できる形にする |
| `.novelpkg`フォルダパッケージ | ローカル所有、復旧、将来のWindows互換を訴求できる | schema、検証器、互換fixture、復旧手順、外部バックアップを整備する |
| 2秒デバウンス + revisionベース保存 | 高頻度変更を直列化して保存できる | 失敗回復、外部変更検出、ディスク枯渇、クラウド同期衝突まで広げる |
| TXT / Markdown / EPUB 3の独立した出力層 | ストレージ内部と出力を分離している | 出力プロファイル、プレビュー、メタデータ、epubcheck、DOCX/PDFへ発展させる |
| ドキュメントに残された設計判断 | 将来の変更理由を追える | 商品判断と技術判断を分け、古い完了記録の実装ドリフトを定期監査する |

### 2.2 現時点の成熟度

| 領域 | 評価 | コメント |
|---|---|---|
| 基本執筆 | B | 章・話、本文、メモ、文字数、自動字下げは成立。ただし全稿検索置換、校正、明示保存、長文計測が不足 |
| 構造管理 | B- | 機能面は広いが、本文箇所への深いリンク、タグ、関係、時系列、差分が弱い |
| データ安全性 | D | 正常系は丁寧だが、読込失敗・不正UTF-8・孤児データ・外部移動・復旧・バックアップに重大な穴 |
| 入出力 | C | 3形式は動くが、移行用import、DOCX/PDF、投稿サイト、商用EPUB品質が不足 |
| UI/UX | C+ | Workbenchとして形はあるが、未完成AI、強制dark、情報密度、初回導線、空状態、削除回復に課題 |
| アクセシビリティ | D+ | セマンティックUIの恩恵はあるが、実機監査・キーボード完全性・VoiceOver・コントラスト証明がない |
| 配布・更新 | E | ad hoc署名、Hardened Runtime無効、公証なし、AppIcon/UTType/更新経路なし |
| 商取引・サポート | E | 価格、試用、ライセンス、規約、返金、特商法、サポート、障害対応が未設計 |
| 競争上の差別化 | C | ローカル所有と日本語長編は有望だが、名称衝突と「AIチャット」のコモディティ化が重い |

## 3. そもそもの思想からの精査

### 3.1 現思想の問題

#### 問題A: 「何を作れるか」が「何を約束するか」に先行している

現在の設計は、EditorPlugin、人物、プロット、伏線、資料、世界観、AI、Windowsなど、実装可能なサブシステムを順に積んでいる。一方で、顧客が金を払う中心的な約束、対象外、最も避けるべき失敗、競合から乗り換える理由は明文化されていない。

その結果、基本的な原稿安全性や入出力よりAIが先になり、UIにも未接続AIが常設されている。これは「ロードマップが製品体験を支配している」状態である。

#### 問題B: 構造化の便利さと、執筆の没入が競合している

長編には構造が必要だが、多くの長編作者にとって、毎文を書く瞬間までプロジェクト管理UIを感じることは集中の妨げになり得る。現在のWorkbenchは多くのセクションとペインを持ち、能力を見せやすい反面、白紙へ向かう心理的距離を伸ばす可能性がある。

構造機能は削るのではなく、次の二層に分けるべきである。

- **Desk層:** 今書く本文、直前の文脈、最低限のナビゲーション、静かな保存状態
- **Studio層:** プロット、人物、伏線、資料、レビュー、出力、AI

通常はDesk層だけが前景にあり、ショートカットや意図的な操作でStudio層が現れるのが望ましい。

#### 問題C: 「日本語向け」の意味がまだ浅い

日本語IMEと全角字下げは重要だが、それだけでは「日本語小説向け」とは言い切れない。縦書き、ルビ、傍点、三点リーダ、ダッシュ、禁則、原稿用紙換算、公募形式、投稿サイト記法、話者の呼称、表記揺れなど、日本語長編の実務には広い期待がある。

すべてを今すぐ実装する必要はない。しかし、横書きWeb小説に絞るならその代わりに、投稿サイト向け記法、話単位運用、スマートなコピー、文字数上限、更新管理を深くする必要がある。対象を広く言うほど、縦書き非対応は「非目標」ではなく「欠落」に見える。

#### 問題D: ローカルファーストが技術選択に留まっている

ローカル保存は強い価値だが、現在は「Sandboxを避け、パスを保存しやすい」という実装上の理由が前面にある。顧客にとっての意味は次である。

- アカウントを作らず書き始められる
- 解約後も原稿を開き、救出できる
- AIを使わない限り本文は外へ出ない
- 作品フォルダを自分でバックアップ・移動できる
- サービス終了後もデータを読める

この約束を、UI、規約、形式仕様、更新、ライセンス切れ時の挙動まで貫く必要がある。

#### 問題E: 「AI支援」の境界が価値ではなく面積になっている

常設チャット、提案、選択範囲操作の3タブは実装の器であり、作者の成果ではない。2026年の競合には全文脈AI、BYOK、ローカルモデル、AI編集者という訴求が既にある。NovelWriterが勝てるのは、チャットの広さではなく次の狭く深い仕事である。

- 設定違反、時系列、呼称、口調、POV、伏線の不整合を根拠付きで見つける
- どの文を根拠にしたか示し、該当箇所へ移動する
- 提案を差分で提示し、作者が一つずつ採否を決める
- 送信範囲、事業者、モデル、費用、保存方針を事前に示す
- AIを完全に隠し、利用履歴がないことも確認できる

### 3.2 推奨する製品原則

今後の判断を次の原則に通すことを推奨する。

1. **原稿主権:** 作者の原稿、順序、Undo、履歴を勝手に変えない。
2. **静かな信頼:** 保存、安全、オフライン状態は確認できるが、執筆を邪魔しない。
3. **段階的開示:** 初めての人には単純、必要になった人には深い。
4. **根拠への往復:** 人物・伏線・AI・検索結果は必ず本文の根拠箇所へ戻れる。
5. **救出可能:** 課金、障害、サービス終了、OS変更にかかわらず一般形式へ出せる。
6. **日本語の実務:** 見た目の和風化ではなく、入力・校正・投稿・組版の摩擦を減らす。
7. **選べる知能:** AIは任意で、送信と変更は常に明示的。
8. **機能より日課:** 新機能は「今日続きを書き、迷わず保存し、必要な形式で出す」循環を壊さない。
9. **失敗を説明する:** エラーを黙って代替せず、何が保護され、何を選べるかを示す。
10. **作者を採点しない:** 目標や統計は励ますために使い、罪悪感や連続日数への依存を生まない。

### 3.3 狙う顧客と狙わない顧客

| セグメント | 現在との相性 | 必須条件 | 判断 |
|---|---:|---|---|
| Mac中心の横書き長編/Web小説・ソロ作者 | 高い | 安全性、全稿検索、投稿向け出力、復旧、集中UI | **一次ターゲット** |
| クラウドロックインやAI強制を嫌う作者 | 高い | 完全オフライン、AI完全OFF、可搬形式、買切り | **一次ターゲット** |
| 文芸公募・商業出版を目指す作者 | 中 | DOCX、縦書き確認、原稿用紙/PDF、コメント・校正 | P1後半以降 |
| 同人誌・セルフ出版作者 | 中 | 商用品質EPUB/PDF、表紙、奥付、組版、検証 | P2以降 |
| Windows中心の作者 | 低 | W0〜W4、MSIX、双方向round-trip | PMF確認後 |
| スマートフォン中心の作者 | 低 | モバイル編集、同期、競合水準のオフライン | 当面は非対象 |
| リアルタイム共同執筆チーム | 低 | 競合編集、権限、コメント、履歴、同期基盤 | 非対象を明記 |
| 脚本・ゲームシナリオ専業 | 低 | 専用形式、分岐、台本レイアウト | 別製品級、当面非対象 |

縦書きに関しては、曖昧な中間を避けて次のどちらかを商品判断として選ぶ。

- **Web連載集中:** Editorは横書きのまま。投稿サイト記法、話単位workflow、安全なcopy、目標、更新履歴を競合以上に深くする。縦書きは「非対応」と購入前に明示する。
- **公募・出版へ拡張:** 縦書きEditorまでは後回しでも、縦書きpreview/output、原稿用紙、DOCX/PDF、ruby/bouten、禁則を1.0〜1.xの契約に入れる。

「日本語小説全般」と宣伝しながら、縦書き・提出形式を無期限で非目標にする選択だけは避ける。

## 4. 商業化を止めるP0問題

### 4.1 真の発売停止条件

ここでは「一般の利用者から代金を受け取る前に、未解決なら発売を止める」条件だけへ絞る。見栄えや利便性の重要項目は次のP1へ分ける。

| ID | 問題 | 現状の危険 | 課金前の受入条件 |
|---|---|---|---|
| P0-01 | 名称clearanceと権利chainが未確認 | 既存`novelWriter`との混同が大きく、全code、asset、font、generated materialを販売できる権利証跡も発売前に確認が必要 | 名称clearanceと改名判断。全commit/素材/依存物の権利chainとthird-party noticeを監査 |
| P0-02 | 起動時の編集可能プレースホルダー | 起動直後の入力が非同期bootstrapによる作品差替えで消え得る | 読込完了まで本文を編集不可にし、遅延読込UIテストで入力消失0を確認 |
| P0-03 | 前回作品読込失敗の無言フォールバック | 新規作品が表示され「原稿が消えた」と見えるうえ、recent pathも新規側へ更新される | 原本を変更せずRecovery画面で停止し、再試行/Finder/修復コピー/別作品/新規を明示選択 |
| P0-04 | 読めないpayloadを正常な空値へ劣化 | 不正UTF-8やI/O失敗を空へ潰し、通常autosaveで原本を置換し得る。既知directory内の未参照本文・メモ・世界観payloadも次回保存で落ち得る | 正常/recovery/read拒否を分離。invalid bytesと孤児payloadを保全し、修復コピー以外へautosaveしない |
| P0-05 | `.novelpkg`のMac安全性検証未完了 | duplicate ID、不正参照、symlink/path escape、過大入力を十分検証せず、破損やpackage外アクセスにつながり得る | Macでも必要なschema/reference integrity、symlink/path、size limit、validator、corrupt fixture、migration前backupを完成 |
| P0-06 | 外部変更と保存障害の救出契約がない | Finder移動後の旧パス再作成、同期競合上書き、保存失敗、終了時失敗でどの原稿が安全か分からない | file identity/外部変更/競合を検出し、保存を停止。再試行/比較/別名保存/Recovery Storeで未保存本文を救出 |
| P0-07 | 商用配布物として署名・公証されていない | 監査したローカル成果物はad hoc署名、Hardened Runtime無効、Gatekeeper reject | 最終Release ArchiveをDeveloper ID署名・公証・stapleし、quarantine付きclean MacでGatekeeper受入と主要E2Eを確認 |
| P0-08 | 販売・プライバシー・サポート契約がない | 購入者が価格、返金、データ、連絡先、障害時対応を判断できない | EULA、Privacy、特商法、返金、動作環境、support、security窓口、試用/解約後の原稿救出を公開 |
| P0-09 | AIを出す場合の外部送信契約がない | 本文や人物資料を、送信範囲・provider・保持・費用が曖昧なまま外部提供し得る | **AI同梱時のみ発売停止条件。** 初期OFF、完全非表示、送信preview、provider固定、Keychain、費用上限、diff/Undo、削除を用意 |

### 4.2 P1の有償ベータ〜1.0ゲート

| ID | 問題 | 必要な改善 |
|---|---|---|
| P1-01 | Snapshotが同一package内だけで、作成・保持・比較が弱い | package外backup、原子的確定、自動世代、名前/memo、diff、部分復元、復元演習 |
| P1-02 | 明示保存と保存状態の情報が弱い | 失敗表示と再試行は実装済み。さらにCmd+Sを`saveNow()`へ結線し、最終成功時刻、原因、保護範囲、Save As/救出、終了時選択を揃える |
| P1-03 | 構造削除が確認dialog頼み | ゴミ箱/操作Undo、影響関係の表示、削除前安全版を用意 |
| P1-04 | AppIcon・UTType・document associationがない | AppIcon、package icon、UTType、Open With、double-click、represented URLを整備 |
| P1-05 | 安全な更新経路がない | 署名付き更新、段階配信、release note、失敗時rollback、最低OS/旧format方針を決定 |
| P1-06 | 未完成AIとダミーstatusが常設 | 接続済み価値が成立するまで非表示。実装後も完全OFF/非表示を可能にする |
| P1-07 | dark外観を強制 | System/Light/Dark、Increase Contrast、Reduce Transparency/Motionで実機QA |
| P1-08 | Welcome/Import/Recentがない | 新規・開く・既存原稿取込・最近の作品・sampleを分かりやすく提供 |
| P1-09 | Release品質gateがunit/build中心 | Release artifact、実IME、長文、障害注入、VoiceOver、CPU/OS matrixを試験 |
| P1-10 | 絶対パスとerrorを`print`する | pathをredactしたstructured local logと、利用者が確認して送るdiagnostic bundleを用意。本文は今後も記録しない |
| P1-11 | 全稿検索/置換、Import、復旧比較が不足 | AIより先に長編の移行・推敲・救出の中心flowを完成 |
| P1-12 | ライセンス/更新障害時の継続利用が未設計 | offline graceと、試用/解約後も閲覧・copy・標準形式exportできる救出保証を実装 |
| P1-13 | 公開repoの許諾・貢献方針が未表示 | no-LICENSEは通常第三者へ利用許諾を与えない状態であり、著作権者自身の販売権を奪うものではない。proprietary/OSS/open-coreを決め、必要ならLICENSEとCLA/DCOを公開 |
| P1-14 | Windows portability契約が未完了 | case/Unicode衝突、予約名、path budget、canonical schema、golden round-tripはWindows互換を広告する前にW0として完了。Mac単体betaの発売停止条件とは分ける |

### 4.3 Apple配布要件とのギャップ

Appleは、App Store外で配るmacOSアプリについてDeveloper ID署名と公証を案内しており、公証ワークフローではHardened Runtimeとsecure timestampが前提になる。現行`project.yml`は`ENABLE_HARDENED_RUNTIME: NO`で、直近成果物はad hoc署名・公証なし・Gatekeeper rejectだった。公式資料は[Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)と[Preparing your app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution)を正とする。

Mac App Storeへ出す場合はApp Sandboxが必要であり、現行D-011を破棄する設計判断、security-scoped bookmark、ファイルアクセス、ライセンス・更新経路の再設計が必要になる。[Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)を参照。初期の直販とApp Storeを一つのビルド設定で曖昧に両立させない。

直販でもSandboxを採用することはできる。D-011は実装簡略化を主な理由としているため、network AI、外部package、資料preview、updateを加える前に、非Sandboxの攻撃面とSandbox採用時のfile access/UXコストを改めて比較し、採否と代替防御を記録する。

### 4.4 監査時点の配布物スナップショット

以下は、repo内のuntrackedローカル成果物`NovelApp 2026-07-16 23-51-50/NovelWriter.app`を、source checkout `462233d`上で`codesign -dvvv`、entitlements表示、`spctl -a -vv`、`lipo -archs`、`plutil`により読取専用検査した結果である。成果物がそのSHAから生成されたことは証明できず、配布候補として作られたものでもない。したがって「現在のローカルpackage工程の参考証跡」であり、正式Release artifactの判定ではない。

| 項目 | 2026-07-19時点で確認した状態 | 商用版で必要 |
|---|---|---|
| Version | `0.1.0 (1)` | versioning、channel、format互換表、release note |
| Architecture | arm64 + x86_64のuniversal | 実機/clean VMで両方の方針を検証 |
| Code signature | ad hoc、TeamIdentifierなし | Developer ID Application |
| Hardened Runtime | 無効 | 有効化し、必要entitlementを最小化 |
| Notarization | なし | submit、accept、staple、ticket確認 |
| Gatekeeper | `spctl`でrejected | quarantine付きdownloadからaccepted |
| Entitlements | 実質空 | 直販で本当に必要なものだけを明文化 |
| App icon | AssetsにはAccentColorのみ | AppIcon一式、package/document icon |
| Document type | UTType/Document Typesなし | `.novelpkg`の宣言、Open With、double-click |
| Info metadata | copyright空、development regionは英語 | 表示名、copyright、localization、category等を整備 |
| Installer/update | なし | 公証済みDMGと署名付き自動更新 |
| Public release | GitHub上にtag/releaseなし | stable download、checksum、changelog、archive |
| Public legal docs | LICENSE/Privacy/Security等なし | 商品/IP方針に応じた公開文書 |
| End-user docs | READMEは主に開発者向け | Start guide、manual、recovery、FAQ、support |

Universal binaryであることは良い材料だが、buildできることと配布できることは別である。Release configurationでArchiveした最終成果物だけを発売判定に使う。

## 5. 基本執筆体験の監査

### 5.1 起動から最初の一文まで

現在は「すぐ本文を見せる」ことを優先しているが、安全性と理解可能性を損なっている。望ましい流れは次である。

1. Welcome画面で前回作品、最近使った作品、新規、開く、サンプルを提示する。
2. 前回作品を自動復元する設定なら、作品名と場所を示した非編集のloading stateを使う。
3. 読込失敗時は新規作品へ勝手に移らず、原本を変更していないことを最上段に示す。
4. 新規作成では、作品名、保存先、目的別テンプレートを選ぶ。後から変更できることも示す。
5. 初回のみ、章→話→本文の関係を実データを壊さないcoach markで案内する。
6. 「今は本文だけ書く」を選べば、人物やプロットを一切設定せず開始できる。

初回に聞きすぎない。作品名と保存先以外はスキップ可能にし、テンプレートは「空白」「Web連載」「長編」「公募準備」程度に留める。

### 5.2 本文エディタ

#### P0/P1で必要

- Cmd+Sの即時保存、最終保存時刻、未保存/保存中/失敗の明確な状態
- 全稿検索、現在話検索、置換、すべて置換、検索結果一覧、前後文脈、該当範囲へのジャンプ
- 正規表現は上級者向けに折りたたみ、通常検索を複雑にしない
- Unicode正規化差、全角/半角、ひらがな/カタカナ、濁点結合を考慮する検索オプション
- 話を移動して戻っても失われないUndo履歴、またはその制約を補う安全な操作履歴
- スペル、文法、スマート引用符、ダッシュ置換、テキスト置換を一律OFFではなく設定化
- 自動字下げ、対括弧、三点リーダ、ダッシュ、ルビ記法などを個別にON/OFFできる入力支援
- 選択範囲、カーソル位置、スクロール位置を話ごとに復元
- アプリ再起動後も「最後に書いていた場所」へ戻れる
- 本文へフォーカスする一貫したショートカット、サイドバー/Inspectorを閉じるショートカット
- 読み取り専用、外部変更、保存失敗中は本文上部にも明示し、色だけで伝えない

#### P2で効く

- Typewriter scroll: 現在行を画面の一定位置に保つ。位置は上/中央/下から選択可能
- Focus mode: 現在文、現在段落、現在話のいずれかを静かに強調
- 文体を変えない最小校正: 括弧対応、連続句読点、空白、表記揺れ、同一段落重複
- 既存の三点リーダー、ダッシュ、ルビ、傍点commandを一つの日本語記号paletteへ統合し、各種括弧と選択範囲を一回のUndoで包む操作へ拡張
- 検索・校正・AIのすべてを同じ「レビューキュー」に載せ、本文を勝手に変更しない
- 一時退避: 削りたくない段落を「切り抜き箱」へ移し、作品内で検索・復元できる
- 読み上げ: 選択/話/章を音声確認し、再生位置を本文highlightへ同期。OS音声を既定にして外部送信しない
- Dictation利用時もIME guard、Undo、autosave、句読点が通常入力と同じ契約を守る
- コメント/annotation: 本文を変更せず推敲メモをrangeへ付け、古くなったanchorを検出する

### 5.3 文字数と進捗

単一の「文字数」では作者ごとの実務に足りない。

- 現在話、現在章、全稿、選択範囲
- 空白を含む/除く、改行を含む/除く
- 原稿用紙400字換算
- 投稿先の上限と現在値
- 今日の純増、追加、削除を分ける
- 目標文字数と締切から必要ペースを出すが、常時表示しない
- 連続執筆日数を罰として使わない。「戻ってきた日」を肯定する
- 統計は本文内容を送らず、ローカル計算を既定にする

### 5.4 ナビゲーション

- Quick Openで章・話・人物・設定・資料を横断検索
- Cmd+P等のコマンドパレットで「行き先」と「操作」を同じ場所から実行
- 現在位置のbreadcrumbを、狭い画面でも意味が残る形で表示
- 最近編集した話、ピン留め、しおり、戻る/進む履歴
- Outline検索をスクロール方向に依存して出現させず、常に発見可能な入口を置く
- タイトル内ヒットと本文内ヒットを区別し、スニペットと件数を表示
- 話移動やモード遷移後も、戻る操作で元のカーソル位置へ帰れる
- 大量の章・話でvirtualization、折りたたみ、フィルタ、キーボード並べ替えを保証

### 5.5 構造編集の安全性

章・話の追加、削除、移動、結合、分割、複製、タイトル変更は本文編集と同じくらい重要である。

- すべての構造操作をUndo可能にするか、ゴミ箱へ送る
- 削除確認では「何文字、何話、どの伏線/人物参照が影響するか」を示す
- 章を削除しても話を「未分類」へ退避できる
- 話の分割は現在カーソル位置から実行し、前後タイトルを確認できる
- 話の結合は区切りとタイトル処理をプレビューする
- 大規模移動前に自動スナップショットを作る
- ドラッグだけに依存せず、キーボードとメニューでも同等操作を提供する

## 6. 情報設計とUI/UXの監査

### 6.1 現在のWorkbench

現行UIは、作品情報、執筆、プロット、登場人物、世界観、資料、設定を単一ウィンドウ内で切り替える。各領域にOutline/Editor/Inspectorを割り当てる規則性は良い。一方で、規則性を優先し過ぎると、内容が少ない領域にも同じ面積と階層が生まれ、「何でも三列の管理画面」に見える。

推奨する基本形は次である。

| 状況 | 前景に置くもの | 奥へ退けるもの |
|---|---|---|
| 書き始め | 現在話、本文、章話Outline、保存状態 | AI、詳細Inspector、全作品統計、設定 |
| 構成を考える | プロットカード、章、伏線、必要なら本文プレビュー | 本文ツールバーの細部 |
| 推敲する | 本文、検索/校正/AIレビュー、diff | 新規作成系UI |
| 資料を参照する | 本文と資料のsplit、Quick Look | 作品設定の他領域 |
| 出力する | 出力プロファイル、プレビュー、検証結果 | 編集用Inspector |

### 6.2 明確な瑕疵

| 現状 | 問題 | 改善 |
|---|---|---|
| ルートで`.preferredColorScheme(.dark)` | OS設定とライト外観を無視する | System/Light/Darkを設定化し、既定はSystem |
| AI未接続のパネルとダミー行/列が常設 | 未完成感、本文よりロードマップを目立たせる | feature flagで非表示。接続後も利用者が完全に消せる |
| AIステータス領域全体が開閉Button | 保存/文字数表示に見える領域が予期せず開く | 独立した開閉ラベル・chevronを置き、ステータスは非クリック領域にする |
| 6ptのリサイズハンドルをdragのみで操作 | 発見性とアクセシビリティが低い | 明示ハンドル、keyboard step、標準split viewを検討 |
| Settings画面とサイドバー内設定が併存 | どちらが正か分かりにくい | アプリ全体設定はSettings、作品固有設定は作品情報へ分離 |
| 作品情報に絶対パスをそのまま表示 | 情報量とプライバシーの割に価値が低い | 短縮表示、「Finderで表示」、copy時だけフルパス |
| Outline検索はpointer利用時の発見がscroll gestureに依存し、Cmd+Fもfocus依存。別の話内検索とscopeが分かりにくい | 機能を知っていても、何を検索するか予測しにくい | 可視入口とscope labelを置き、Outline/現在話/全稿を一つの検索modelで整理 |
| アイコン中心のtoolbar | hoverできない環境、記憶負荷、VoiceOverに弱い | 重要操作は文字付き、残りはoverflow。初回はラベル表示も可能にする |
| 任意の本文色/背景色 | 読めない組合せを作れる | プリセット、コントラスト判定、初期値へ戻す、System theme |
| 最小8ptまで本文を縮小可能 | 読みづらく誤操作しやすい | 安全な推奨範囲、警告、ズームと文書設定を分離 |
| mode切替で文脈が切れる | 元の本文位置へ戻りづらい | 戻る/進む履歴、split参照、各modeのlast state保持 |
| Empty stateが「選択されていません」中心 | 次の一歩が受動的 | 目的を説明し、主操作を1つだけ提示。サンプル追加は任意 |
| 保存失敗が下部中心 | 本文に集中すると見逃す | ウィンドウ上部/タイトルにも非侵襲な警告。解決まで消えない |

### 6.3 画面密度と余白

- 余白は装飾ではなく「今見るべき領域」の境界として使う。
- Outlineの行高、Inspectorのセクション間隔、本文の左右余白は別トークンにする。
- 3列を狭めた時、Inspector→Outlineの順で畳み、本文幅を最後まで守る。
- 最小ウィンドウ幅を定め、縮小時のラベル省略、toolbar overflow、sheet幅をsnapshot testする。
- 本文最大幅は物理的な紙幅ではなく、文字数/行とフォントで選べるプリセットにする。
- 境界線やmaterialを重ね過ぎない。各ペインの役割は見出し、余白、背景差のどれか一つで示す。
- セクション切替時のanimationは短く、Reduce Motionでは無効にする。本文は移動させない。

### 6.4 文言

- `Outline`など英語ラベルと日本語を混在させない。製品語彙集を作る。
- 「作品」「章」「話」「本文」「メモ」「資料」「スナップショット」の意味をヘルプとUIで固定する。
- エラーは「失敗しました」で終えず、`何が起きた / 原稿は安全か / 次に何をする`の順に書く。
- 破壊操作は対象名を文中に入れる。汎用の「本当に削除しますか？」を避ける。
- 空状態は責めない。「まだありません」より「必要になったら追加できます」を使う。
- AI文言で「正しい」「完成」「盗作なし」「著作権安全」を保証しない。
- キャラクターやプロットのテンプレートは「埋めるべき必須項目」に見せない。

### 6.5 macOSらしさ

- Window titleに作品名と保存状態を載せ、represented URLとproxy iconを提供する。
- Open Recent、Duplicate、Rename、Move To、Revert、Versionsのうち採用する標準契約を決める。
- メニューをUIの付属物ではなく完全な操作面として整え、全操作に一貫した名称を使う。
- toolbar customizationを採用するなら、既定へ戻すこととsmall windowを検証する。
- Quick Look、Finder reveal、Services、Share、standard text commandsを適切に利用する。
- Full Screenでは本文の中央位置とsidebar開閉状態を保持する。
- アプリ終了、ウィンドウ閉じる、作品を閉じるの意味を分ける。保存失敗中は明示する。

## 7. 構成・人物・伏線・世界観・資料

### 7.1 原則: データベース化し過ぎない

作者ごとに構成方法は違う。すべての人物へ年齢、性別、口調、背景を埋めさせたり、すべての話をカード化させたりすると、執筆支援が宿題になる。各機能は次の順で設計する。

1. 自由記述だけでも使える。
2. よく使う属性は任意の構造フィールドにできる。
3. テンプレートを選べるが、空欄を警告しない。
4. 本文から自動推定する場合は候補として出し、確定しない。
5. 構造情報から本文へ、本文から構造情報へ往復できる。

### 7.2 プロット

現在の章紐付きタイトル/メモのカードから、次を段階追加する。

- 未割当、章、話への配置
- status、色、タグ、POV、場所、時刻、登場人物、目的、対立、結果
- カードごとの目標文字数と実文字数
- ボード、Outline、timeline、tableの複数表示。ただし同じデータを使う
- 選択カードに関連する本文を横に開く
- カード順変更と章話順変更の関係を明示し、意図しない本文移動をしない
- ストーリー理論テンプレートはガイドとして提供し、作品を採点しない
- act/arc/volume/partは固定階層にせず、tagまたはgroupから始める
- CSV/Markdownでの一覧出力と再import
- カード削除・章削除時の参照修復とUndo

### 7.3 登場人物

現行には役割、年齢、性別、一人称、二人称、口調、外見、性格、背景のfieldが既にある。これを土台に次へ広げる。

- 別名、愛称、敬称、呼称の相手別管理
- 既存の役割fieldに加え、関係、所属、登場期間、秘密、欲求、変化のarc
- 本文中の名前検出は、短い名前・同名普通名詞・別表記の誤検出を前提に候補表示する
- 手動で登場箇所を追加/除外し、以後の検出に反映する
- 登場話だけでなく本文の実箇所へジャンプする
- 相関図は自動レイアウトだけでなく、作者が位置と線を固定できる
- 画像は任意。パッケージ肥大、著作権、外部参照切れを説明する
- キャラクターシートの項目は表示/非表示・並べ替え・カスタム追加を可能にする
- 会話サンプルや口調メモはAI送信対象から既定で除外し、送信時に明示する
- ある時点の年齢、所属、関係を持つならtimelineと整合するモデルが必要。単純な現在値だけで済む段階では無理に導入しない

### 7.4 伏線

章IDだけでは「どの文で張り、どの文で回収したか」が弱い。

- 張った本文範囲、回収した本文範囲への安定したdeep link
- 複数のヒントと複数の回収
- status: 構想、提示済み、部分回収、回収済み、破棄
- 読者へ見せる情報と、作者だけが知る意味を分ける
- 期限や予定章ではなく、timeline上の前後矛盾も確認する
- 話の移動・分割後もリンクを可能な限り追跡し、壊れたリンクを一覧化する
- 未回収一覧は責める赤ではなく、レビュー対象として静かに示す
- 伏線をクリックすると、張り→中間→回収が一本の糸として表示される

### 7.5 世界観ノート

- folderだけでなくtag、backlink、関連人物/場所/組織/用語
- `[[リンク]]`または選択UIによる内部リンク。リンク名変更でもIDで追従
- 孤立ノート、壊れたリンク、本文から参照されるノートの表示
- 場所、組織、用語、年表など任意テンプレート
- ノート全文検索、見出し、アウトライン、Markdownの最小サポート
- 本文とノートのside-by-side表示
- ノートへ「公知」「登場人物だけが知る」「作者のみ」のknowledge scopeを付ける余地
- 世界観を埋めること自体が目的にならないよう、本文から必要時に一行メモを作れる

### 7.6 資料

現在の取込・一覧・Finder表示から、まず次を加える。

- Quick Look、既定アプリで開く、本文横へ固定
- ドラッグ&ドロップ、Finderからの複数追加、重複検出
- 取込コピーと外部参照の違いを明示。初期は取込コピーを安全な既定にする
- ファイルサイズ、種類、追加日、タグ、メモ、関連人物/話/ノート
- 元ファイル更新の取込し直しと差分説明
- 画像サムネイル、PDFページ移動、テキスト抽出はP2
- 巨大ファイル、実行ファイル、symlink、package、未知形式への上限と警告
- 削除はゴミ箱へ。パッケージ内ファイルを直接消さない
- 書き出し/バックアップ時に資料を含むか選択でき、容量を予告する
- 将来OCRやAIを使う場合、外部送信を本文とは別に許諾する

### 7.7 複数作品・シリーズ

単一作品の品質を固める前にライブラリ機能を大きくしない。ただし一次顧客の利用が定着すれば複数作品・シリーズ需要が生じる、という製品仮説に備え、データ境界は早く決める。

- Welcomeに最近使った作品、pin、archive、last opened、健全性を表示
- 「作品を削除」はFinder上のpackage削除と同義にせず、ライブラリから外す操作と分ける
- seriesは各`.novelpkg`を独立保持し、共有設定を別copyにするかID linkにするか明文化
- 共有人物/世界観を変更した時、過去巻が勝手に変わらないversioningを設計
- シリーズ横断の人物、用語、timeline、全文検索はP2以降
- 作品templateは構造だけを複製し、本文・private資料を誤って含めない
- archive、完成、休止、連載中等は任意のstatusで、評価に使わない
- library metadataを独自cloud DBだけに閉じず、再構築可能にする

### 7.8 編集者との往復

リアルタイム共同編集より先に、非同期のレビュー受渡しを検証する。

- DOCXのcomment/track changesをどこまで往復できるか明示
- 特定版へのcomment、本文rangeへのannotation、resolved status
- reviewer用read-only packageまたは一般形式bundle
- 変更提案をdiffとしてimportし、本文へ自動mergeしない
- 作者用memoと共有commentを明確に分ける
- anonymized review copyを作り、人物資料や未公開メモを除外できる
- version名、送付日、相手、戻り日をlocal記録
- 共同機能を作るなら権限、暗号化、競合、削除、監査logを別商品gateにする

## 8. 検索・推敲・履歴

### 8.1 全稿検索はAIより先

商用の長編ツールで、作品全体の検索・置換は最低限である。

- scope: 選択範囲、現在話、現在章、全本文、メモ、人物、プロット、世界観
- filter: 大文字小文字、全半角、正規表現、単語/表記、除外領域
- 結果に章/話、前後文、件数、更新時刻を表示
- replace前にdiff preview。すべて置換は一操作でUndo可能
- 数千件ヒットでもUIを塞がず、途中キャンセル可能
- 検索結果が話移動後も安定し、本文変更で古くなったことを示す
- 保存されていないNSTextView上の最新本文を検索対象にする

### 8.2 校正

ローカルルールから始めれば、AIなしでも価値が出る。

- 括弧の不一致、閉じ忘れ
- `…`や`―`の個数、類似記号の混在
- 行頭字下げ、会話行、空行の規則
- 全角/半角数字、英字、空白、句読点の表記揺れ
- 同一人物の呼称、一人称、敬称の揺れ
- 固有名詞辞書と無視リスト
- 連続する同一語、近接重複、長すぎる段落は「指摘」だけに留める
- ルールセットを作品/投稿先ごとに保存
- 全指摘に根拠、ルール名、無視、作品全体で無視を用意
- 校正は自動修正せず、review queueで一件ずつ扱う

### 8.3 履歴・比較・復旧

現行は手動snapshot、一覧、確認付き復元を持ち、復元前に現在状態のsnapshotを保存し、working package経由で置換する保護もある。これは強みとして残す。そのうえで、「スナップショットがある」から「事故時に使える履歴とbackup」へ広げる。

- 自動: 一定時間、アプリ更新前、形式migration前、大規模構造変更前
- 手動: 名前と任意メモを付ける。例「第三章を削る前」
- 比較: 文字diff、章話構造diff、人物/プロット等のmetadata diff
- 復元: 現行の復元前保護を維持し、全作品だけでなく話/フィールド単位のpreview復元へ拡張
- 保持: 時間/日/週の世代、容量上限、削除予告、固定して消さない版
- 外部Recovery Store: package外で、同じディスクだけでなく選択先にも複製
- 健全性: hash、manifest inventory、読込確認、復元演習
- UI: 「保存履歴」と「バックアップ」を用語で分ける
- Time Machine等OSバックアップとの併用方法をヘルプにする

## 9. 入力・書き出し・公開フロー

### 9.1 Importが先に必要な理由

有料エディタへの移行候補には、既存原稿を持つ作者が相当数いるという製品仮説を置く。空白から始める人だけを想定すると移行時の試用価値を判断できないため、まず次の順が妥当である。

1. TXT import: encoding判定、改行、章区切りpreview、原本非変更
2. Markdown import: 見出し→章/話のmappingをpreview
3. DOCX import: 本文・見出し・強調・ルビ等の対応表を明示
4. 既存`.novelpkg`の検証・修復コピー
5. Scrivener等の直接importは需要を計測してから

Importは必ず新しい作品を作り、原本を変更しない。自動判定にはpreviewと戻る操作を付け、文字化け、行分割、見出し誤認を保存前に確認させる。

### 9.2 Exportの優先順位

| 形式/導線 | 優先度 | 必要な品質 |
|---|---:|---|
| TXT | P1 | encoding、改行、見出し、空行、投稿先記法、preview |
| Markdown | P1 | 見出し階層、escape、front matter選択、安定した再出力 |
| 投稿サイト向けコピー | P1 | ルビ/傍点/改ページの変換、文字数上限、preview、clipboard確認 |
| DOCX | P1 | 編集者との受渡し、見出し、コメント余地、ルビの方針、Word/Pages検証 |
| PDF | P1後半 | A4、原稿用紙、ページ番号、余白、フォント埋込、縦書き需要の判断 |
| EPUB 3 | P1 | author、cover、description、language、rights、nav、ruby、accessibility、epubcheck |
| HTML | P2 | clean semantics、CSS profile、画像、preview |
| 印刷/同人組版 | P2/P3 | 縦書き、ノンブル、柱、禁則、裁ち落とし等。別レベルの品質計画が必要 |

現在のEPUBは横書き最小仕様としては良いが、販売可能な電子書籍生成器とは呼ばない。`epubcheck`、Apple Books、Kindle Previewer、主要readerで検証し、メタデータ、表紙、ルビ、アクセシビリティを満たしてから位置付けを変える。

### 9.3 投稿サイト連携

初期は自動投稿より「安全な変換・コピー」を優先する。例えばカクヨムは編集画面への貼付が基本で、独自の[ルビ・傍点記法](https://kakuyomu.jp/help/entry/notation)がある。直接自動投稿は認証、規約、画面変更、下書き上書きのリスクが増える。

- 投稿先プロファイルを選ぶ
- 変換される箇所を色付きpreviewする
- 未対応記法を警告する
- 話タイトル、前書き、本文、後書きを別々にコピーできる
- コピー成功と文字数を表示する
- 投稿済み日時・URLはローカル記録に留め、本文と混ぜない
- APIが公式提供される場合だけ、明示確認付きpublishを検討する

### 9.4 出力UI

現在の形式選択Alert→Save Panelから、専用sheetへ発展させる。

- 左: 形式と保存済みプロファイル
- 中央: 章/話の対象、見出し、空行、記法、metadata
- 右: previewと警告
- 下部: 出力先、上書き、推定容量、検証結果
- 前回設定を作品単位で保存するが、packageへOS固有パスは入れない
- 成功後に「Finderで表示」「開く」「もう一度出力」を提示
- 失敗時に一時ファイルや既存出力を傷つけていないことを説明する

## 10. データ安全性・保存形式・セキュリティ

### 10.1 読込状態を3つに分ける

1. **正常:** schema、参照、本文、inventoryが妥当。通常編集とautosaveを許可。
2. **Recovery/read-only:** 一部が壊れているが救出可能。autosave禁止。診断、原bytes、孤児を保持し、「修復コピーを作る」だけ許可。
3. **拒否:** path traversal、symlink、危険な再解析、過大入力など。原本へ一切触れず理由を示す。

「壊れていても開く」を優しさと誤解しない。劣化状態を正常なモデルへ潰してautosaveすることが最も危険である。

欠損判定はschema上の必須性に従う。manifest/world indexが参照する本文・世界観本文は必須だが、空メモのファイルは正常に省略され得る。メモは「存在するのに読めない/不正UTF-8」の場合だけrecovery対象にし、単なる不存在を破損と扱わない。

### 10.2 W0をMac安全性gateとWindows互換gateに分ける

`docs/CROSS_PLATFORM.md`は、W0未完了で、現行Mac writerがportable filenameやpath traversal要件を全て保証していないと明記する。これはWindowsだけの話ではなく、悪意ある/壊れたpackage、iCloud/ZIP/外付けディスク経由の入力、安全なmigrationに関わる。

ただしW0の全項目をMac単体betaの発売停止条件にはしない。

- **Mac課金前P0:** schema/reference integrity、invalid bytes、duplicate IDs、symlink/path escape、resource limit、read-only recovery、migration前backup
- **Mac 1.0のP1:** canonical schema、golden/corrupt fixtureの拡充、forward compatibility、未知field、保存前read-back
- **Windows互換を広告する前のP0:** Windows予約名、case/Unicode正規化衝突、component/full path予算、短いtemp名、Mac↔Windows reader/writer round-trip

最低限のvalidator項目:

- format version、canonical schema、未知必須項目
- UUID形式、duplicate document/chapter/episode/note IDs
- manifest順序、参照整合、孤児、欠損、余剰
- UTF-8、改行、JSONの深さ・サイズ・重複key方針
- symlink、alias、junction/reparse、path traversal
- Windows予約名、末尾dot/space、case/Unicode正規化衝突
- component/full path長、ファイル件数、総容量、単一ファイル上限
- timestamp文法とcanonical出力
- attachment名とMIME/拡張子の不一致
- snapshot inventory、再帰、自己包含
- 未知項目/未知root itemをlosslessに保持できるか

現行の未知root item保持と、既知JSON内の未知field保持は別問題である。後者は既知modelへdecodeして再encodeするだけでは失われ得るため、schemaのforward compatibility方針、raw extension bag、拒否する新版の境界を明文化する。

### 10.3 保存commit

- 同じ親に短い固定prefix + UUIDでworking packageを作る
- 既存packageのinventoryと未知項目を収集する
- 新packageを書き、必須構造と本文のread-backを検証する
- fsync等の耐久性方針を明文化する
- 既存packageを安全に退避し、新packageを原子的に確定する
- 確定後に再読込し、document ID・章話順・本文hash・metadata件数を照合する
- 途中失敗時は旧版を残し、working/backupの場所を回復UIへ渡す
- autosave、attachment操作、snapshot、Save As、exportの排他規則を図示し、race testする

### 10.4 外部変更

- packageのfile identity、volume、mtime/inventory hashを保持
- Finderでmove/renameされた時は追従または選択を求める
- 削除された時は旧場所へ黙って再作成しない
- iCloud/Dropbox等の同期中・conflicted copy・download未完了を検出できる範囲で扱う
- 別プロセス/別Macで変わった場合は自動上書きせず、再読込・比較・別名保存を提示
- ネットワーク/外付けvolume切断時はローカルRecovery Storeへ退避できる
- 保存先変更中に入った本文編集を、新旧どちらへ保存済みか正確に状態化する
- 現行Save Asはcopy後の最終`saveNow()`結果を捨てて成功を返すため、「copyは作成済みだが最新編集は未保存」を区別して呼出元へ返す

### 10.5 脅威モデル

ローカルアプリでも、他人から受け取った作品packageや資料を開く以上、入力は信頼しない。

- path traversalやsymlinkによるpackage外読書き
- 巨大JSON、深いnest、膨大な小ファイルによるresource exhaustion
- HTML/EPUB previewのscript・外部resource・URL scheme
- 画像/PDF/office資料のpreviewによるOS parser exposure
- 更新ファイルの改ざん、downgrade、署名鍵漏洩
- AI API keyの平文保存、ログ露出、clipboard漏洩
- diagnostic uploadへの本文・絶対パス混入
- ライセンスサーバ障害で原稿を開けなくなる設計

Security contact、脆弱性報告方針、更新SLA、鍵ローテーション、release keyのオフライン保全を用意する。

### 10.6 同期は「フォルダへ置けば動く」ではない

現時点で独自同期を作る必要はないが、Documents/iCloud Drive/Dropbox等へ置かれる現実は無視できない。

- 「同期対応」と「同期folderに置ける」を分けて表記する
- file provider上のdownload未完了、eviction、partial package、conflicted copyを試験する
- package全体を書き換える保存方式が同期帯域と競合へ与える影響を計測する
- 同時編集を検出し、last writer winsで黙って上書きしない
- conflict時は作品全体または話単位で比較・救出する
- 将来独自同期を作るなら、end-to-end encryption、key recovery、削除、退会、offline queue、schema migrationをproduct contractにする
- iPad/Windows companionはfull editorより先にread-only参照/quick note需要を検証できるが、別形式を増やさない
- sync障害やservice終了でもlocal packageが単独で完全に開けることを守る

## 11. AI支援の製品・プライバシー設計

### 11.1 AIを入れる前の条件

- AIなしで1.0の中心ループが成立する
- AIパネルを完全に隠せる
- provider/modelごとの送信・保持・学習方針を表示できる
- API keyはKeychainへ保存し、`.novelpkg`やUserDefaultsへ入れない
- 本文、選択範囲、設定、要約のどれを送るかpreviewできる
- 送信前に推定token/費用を示し、上限とcancelを提供する
- responseを本文へ直接書かず、diff proposalとして扱う
- 適用が一操作でUndoでき、IME中は介入しない
- AI履歴を削除・exportでき、本文を含まない監査情報も選べる
- provider障害、rate limit、model廃止、途中responseで原稿を壊さない

OpenRouterはproviderによってloggingや学習方針が異なり得るため、単に「OpenRouterを使えば学習されない」と表示してはいけない。[Provider Data Collection](https://openrouter.ai/docs/guides/privacy/provider-logging/)を基に、ZDR、許可provider、fallback routingを利用者が固定できる設計にする。

個人情報保護委員会は、生成AIへ個人データを入力する際に提供先の利用目的等を確認するよう注意喚起している。[生成AIサービスの利用に関する注意喚起](https://www.ppc.go.jp/news/careful_information/230602_AI_utilize_alert/)と[外国にある第三者への提供](https://www.ppc.go.jp/personalinfo/legal/guidelines_offshore/)を確認し、本文や人物資料に個人情報が含まれ得ることを前提にする。

### 11.2 優先するAI成果

| AI機能 | 価値 | 守るべき境界 |
|---|---|---|
| 整合性レビュー | 人名、年齢、時系列、場所、所持品、設定矛盾 | 根拠文を列挙。確信度を示し、自動修正しない |
| 呼称・口調レビュー | 人物ごとの一人称/二人称/語尾の揺れ | ルールを作者が確定。台詞以外を誤認し得ると示す |
| POVレビュー | 視点逸脱、知り得ない情報 | 文学的技法を誤りと断定しない |
| 伏線レビュー | 未回収、早すぎる開示、関連箇所 | 伏線データと本文根拠を分ける |
| 要約・索引 | 長編の章話概要、人物別出来事 | 原文へのリンクを持ち、古くなった要約を検出 |
| 推敲diff | 冗長、読みやすさ、表記 | 文体を保存する制約、複数案、部分適用 |
| 質問応答 | 「この人物が最後に出たのは？」 | 回答だけでなく引用でない短い根拠要約と位置 |

### 11.3 避けるべきAI

- 起動時から本文全体を自動送信する
- providerやmodelを曖昧にした自動routing
- 「続きを書く」を主役にして作者の主体性を薄める
- responseをカーソル位置へ即挿入する
- 根拠なしに「矛盾」「盗作」「著作権安全」と断定する
- AI機能を使わないと基本編集まで制限する
- credit残量を執筆中に煽る
- 学習不使用、保存ゼロを全providerに一括保証する
- AI生成履歴を消せず、原稿のprovenanceも説明できない

文化庁の[AIと著作権に関する整理](https://www.bunka.go.jp/seisaku/chosakuken/aiandcopyright.html)に照らしても、創作的寄与や類似性・依拠性は個別事情に依存する。「AIを使えば権利上安全」などの保証は行わない。

### 11.4 UI案

常設チャットではなく「レビュー」を中心にする。

1. 作者が対象範囲とレビュー目的を選ぶ。
2. 送信内容・provider・費用・privacyを確認する。
3. 非同期で処理し、執筆は続けられる。
4. 結果は話/項目別のreview inboxへ入る。
5. 各指摘に根拠、移動、採用、無視、ルール化を付ける。
6. 変更案はdiffで適用し、Undoできる。
7. 結果を消す、AI履歴を消す、作品単位でAIを永久OFFにできる。

## 12. アクセシビリティ、性能、品質保証

### 12.1 アクセシビリティ受入条件

- VoiceOverだけで新規作成、作品を開く、話選択、本文入力、保存、検索、出力、復旧ができる
- すべてのアイコンButtonに固有のlabel/help/valueがある
- keyboard-onlyで同じ主要操作ができ、focus ringと順序が自然
- drag操作には上/下/移動先Menu等の代替がある
- 色だけでstatus、選択、伏線状態、保存失敗を示さない
- Light/Dark/Increase Contrast/Reduce Transparency/Reduce Motionで崩れない
- 本文拡大、OS display zoom、狭いwindowでも操作が消えない
- custom text/background色にコントラスト警告とresetがある
- resize handleや小アイコンのhit targetを十分に取る
- 日本語VoiceOver読み上げで略語、英語混在、記号名を確認する
- Dictation、かな/ローマ字/ライブ変換、絵文字、サロゲートペアで壊れない
- Accessibility Inspectorの結果をrelease checklistへ添付する

### 12.2 長文性能

毎変更で`textView.string`全体をモデルへ渡し、UIが全作品文字数を再集計する構造は、規模が大きくなると入力遅延源になり得る。推測で最適化せず、次のfixtureで計測する。

| Fixture | 目的 |
|---|---|
| 1話1万字、全稿10万字 | 日常の基準 |
| 1話10万字、全稿100万字 | 大きな話と長編 |
| 1話30万字、全稿300万字 | ストレス上限 |
| 500章/5,000話 | Outlineと検索のscalability |
| 人物2,000、カード10,000、資料5,000 | metadataと一覧のscalability |
| 1GB資料を含むpackage | 保存・snapshot・backup容量挙動 |

測定項目:

- key-downからglyph表示、IME確定、Undo/Redo
- 話切替、初回読込、autosave、snapshot、export
- 検索初回結果と全件完了、cancel反応
- CPU、memory peak、I/O、energy impact
- UI main thread stall、scroll hitch、selection保持
- 冷起動/温起動、Intel/Apple Silicon、macOS 14以降

目標値を先に決め、releaseごとに回帰を記録する。文字数は差分更新またはbackground indexを検討するが、NSTextViewの本文所有権を崩さない。

### 12.3 テストマトリクス

#### 保存・障害注入

- disk full、quota、read-only、permission変更
- volume unplug、network timeout、file lock
- working package各段階でprocess kill/power loss相当
- 外部rename/move/delete、concurrent writer、iCloud conflict
- invalid UTF-8、truncated JSON、duplicate IDs、orphan、symlink、巨大入力
- v1/v2/v3 migration、downgrade、新版を旧版で開く
- Save As中の継続入力、attachment追加中のautosave、snapshot中の終了

#### UI/E2E

- 初回起動、Welcome、新規、開く、最近使った項目
- 読込失敗→recovery→修復コピー
- IMEかな/ローマ字/ライブ変換、Undo、話切替
- 検索置換、構造Undo、ゴミ箱復元
- export preview→成功/失敗→Finder
- update成功、途中失敗、rollback
- VoiceOver/keyboard-only/Reduce Motion
- clean user account、clean Mac、offline、proxy、時計ずれ

#### Release artifact

- Release configurationのArchiveを試験対象にする
- `codesign --verify --strict --deep`、`spctl`、notary ticket、staple
- entitlementsとlinked frameworksを監査
- universal binaryまたはsupport architecture方針を明記
- DMG/ZIPのinstall、quarantine、初回起動、update
- SHA-256、SBOM/第三者notice、dSYM/archive、version/build整合
- epubcheckと実reader、DOCX/PDFの実アプリ検証

ローカルCI方針を維持する場合でも、商用releaseはクリーンな別machine/VMから再現可能でなければならない。開発機の偶然の状態に依存しないrelease runbookを用意する。

### 12.4 保守性と文書ドリフト

商用化後は、機能を足す速度より、事故を切り分けて修正を配る速度が重要になる。

- `AppState.swift`は作品ライフサイクル、選択、保存、資料、snapshot、各種編集操作を抱えた大きな型になっている。DocumentSession、Recovery、navigation、feature-specific coordinatorへ責務を分ける
- UI2後も`AppMode.swift`等の旧名や、PHASE5に残ったrename taskがあり、設計の現在地が読みにくい
- PHASE4/UIDESIGNの未完了checklistには、実装済みに見える項目と本当に未完了の項目が混在する。完了記録とbacklogを分離する
- DESIGNのview tree、実在型、画面語彙をreleaseごとに照合する
- SwiftLintの対象をNovelKitだけでなくNovelApp/Testsにも広げ、warningをrelease failureにするか例外理由を記録する
- 監査時点のfile length/type body length warningを解消し、「警告ゼロ」という文書と一致させる
- 日本語文字列の直書きをlocalization catalogへ移し、表記統一と将来のWindows共有に備える
- errorを`print`と`Bool`だけで潰さず、typed error、user recovery option、structured local logへ分ける
- package migration、release、recovery、key rotation、hotfixを個人の記憶ではなくrunbookにする
- 重要決定は技術上のD-XXXと、商品上のpricing/positioning/release decisionを分けて記録する

## 13. 市場、名称、競合、差別化

### 13.1 名称は最初のP0

無料OSSの[`novelWriter`](https://novelwriter.io/)は、執筆・構成・人物/場所/物品タグ・相互参照等を持つ成熟した小説制作アプリである。現名称の大文字小文字差だけでは、次の問題を避けられない。

- 検索結果で既存製品に埋もれる
- 「NovelWriterの不具合」がどちらの製品か分からない
- レビュー、動画、SNS、FAQ、ドメインが混ざる
- ユーザーが既存製品のfork/後継/公式版と誤認する
- 将来の商標、ストア審査、広告運用、SEOに無駄な摩擦が生じる

侵害が確定しているとは本レポートでは判断しない。商業化前に[J-PlatPat](https://www.j-platpat.inpit.go.jp/t0100)で関連区分を調査し、弁理士によるclearanceを行う。App Store、Microsoft Store、ドメイン、GitHub、SNS handleも同時に確保する。

新名称の条件:

- 日本語で読みやすく、音声で伝えて綴れる
- 一般名詞2語の直結を避け、検索固有性がある
- 日本語だけに閉じず、Windows版でも扱える
- 「AI」を名前に入れず、AIなしでも価値が残る
- 小説専用であることをsubtitleで補える
- ロゴを16pxでも識別できる
- package拡張子とbundle IDをどう移行するか決められる

名称案を作る場合も、監査未済みの案を製品名として採用しない。「書斎」「机」「綴る」「章」「灯」「栞」「庭」等はブランドterritoryとして探索し、法的・検索的な評価を別工程で行う。

### 13.2 競合から見える最低期待値

| 競合 | 公開上の強み | NovelWriterへの示唆 |
|---|---|---|
| [Nola](https://apps.apple.com/jp/app/nola-%E5%B0%8F%E8%AA%AC%E3%82%92%E6%9B%B8%E3%81%8F%E4%BA%BA%E3%81%AE%E3%81%9F%E3%82%81%E3%81%AE%E5%9F%B7%E7%AD%86%E3%82%A8%E3%83%87%E3%82%A3%E3%82%BF%E3%83%84%E3%83%BC%E3%83%AB/id1468307521) | プロット、人物、縦書きpreview、複数端末、国内認知 | 機能一覧の正面衝突を避け、Macネイティブ・ローカル所有・長文操作の深さを出す |
| [TATEditor](https://tateditor.app/) | 縦横WYSIWYG、ルビ/傍点、正規表現、PDF、原稿用紙等 | 「日本語向け」を名乗る時の出力・記法期待値を示す。無料競合と機能数で戦わない |
| [Novel Airline](https://apps.apple.com/jp/app/novel-airline/id1499642698) | 縦書き、ルビ/傍点、構成資料、履歴、PDF等 | mobile中心作者の期待値と、書く→出すの連続性を示す |
| [Story Plotter](https://apps.apple.com/jp/app/%E3%82%B9%E3%83%88%E3%83%BC%E3%83%AA%E3%83%BC%E3%83%97%E3%83%AD%E3%83%83%E3%82%BF%E3%83%BC-%E3%83%8D%E3%82%BF-%E3%81%8B%E3%82%89-%E3%83%97%E3%83%AD%E3%83%83%E3%83%88-%E3%82%92/id1491980862) | 物語論templateと発想・構成支援 | template数で競わず、原稿の根拠箇所との結合で差別化 |
| [Core](https://corewrite.app/en/) | macOSネイティブ、AI編集、research、縦書きを訴求 | 「AIは編集者」という言葉自体も差別化にならない。privacyと根拠・差分の実装で証明する |
| [novelWriter](https://novelwriter.io/features.html) | 無料OSS、plain text、構造、タグ、相互参照 | 名称変更が必要。可搬性だけでは差別化にならない |
| [Scrivener](https://www.literatureandlatte.com/scrivener/overview) | Binder、Corkboard、資料併置、目標、Compile、広い入出力 | 成熟した万能型を追わず、日本語の連続体験と分かりやすさで勝つ |
| [iA Writer](https://ia.net/ja/writer/support/editor/authorship) | 集中、ローカル中心、Authorship | 静かな本文体験とAI provenanceは既に市場価値。NovelWriter固有の長編構造へ結ぶ |
| [Ulysses](https://help.ulysses.app/en_US/getting-started/details-and-tips) | 集中、目標、統計、校正、backupの一体験 | feature siloではなく執筆→推敲→提出の連続性を磨く |
| [Storyist](https://storyist.com/mac/) | 原稿/脚本、page layout、目標、version、広いimport/export | professional workflowを狙う時のversionと受渡し期待値 |
| [Plottr](https://plottr.com/pricing/) | plot template、timeline、No AI訴求 | AIを使わないことも有料価値になる |
| [Novelcrafter](https://www.novelcrafter.com/) | Codex、BYOK、共同作業、複数model | BYOKやchatだけでは差別化不足。根拠付き整合性レビューへ絞る |
| [Sudowrite](https://sudowrite.com/pricing) | 生成AI中心のcredit subscription | AI原価とquotaを隠さず、基本editorの価値をcreditから分離する |
| [Atticus](https://www.atticus.io/) | 執筆から商用品質book formatting | セルフ出版を狙うならEPUB/PDFの品質は別の製品柱になる |

国内外の全競合を機能単位で追いかけると、モバイル、同期、共同編集、縦書き、組版、AI、出版、脚本まで無限に広がる。差別化は「少ない機能」ではなく、次の組合せに置く。

> Local sovereignty × Japanese long-form continuity × evidence-based optional intelligence

日本語では次の4つに翻訳できる。

- **手元:** 原稿はローカルにあり、アカウントや解約に支配されない
- **続き:** 昨日と同じ場所、文脈、Undoから再開できる
- **つながり:** 本文・人物・設定・伏線が根拠箇所で結ばれる
- **選択:** AIを招くか、何を見せるか、どの提案を採るかを作者が決める

### 13.3 競争しない領域

- 同時共同編集を初期に作らない
- 独自クラウドをPMF前に作らない
- AIのmodel数や「何でも生成」で競わない
- DTP級組版を軽く約束しない
- WindowsとiPadを同時に作らない
- 一般ノートアプリや汎用Markdown editorへ広げない
- 公開サイトへの自動投稿を公式APIなしで行わない
- 作家をランキング化するsocial/gamificationを入れない

## 14. 価格、試用、課金、流通

### 14.1 価格は仮説として検証する

現時点の推奨仮説:

利用者へのWTP調査はまだ行っていないため、以下は発売価格の決定ではない。対象作者への価格interview、5,800円/7,800円での実購入意向、更新権、support原価、税込表示を揃えて検証するための初期レンジである。

| 商品 | 仮説価格 | 条件 |
|---|---:|---|
| 早期有償beta Mac | 税込5,800円買切り | P0解消、Import、全稿検索、復旧、署名更新、明確な未完成範囲 |
| Mac 1.x Standard | 税込7,800円買切り | DOCX/PDFまたは対象顧客に十分な投稿出力、商用support、品質gate |
| Windows crossgrade | 税込4,000円前後 | Windows版完成後。OS別単体価格は同等 |
| Mac + Windows bundle | 税込11,800円前後 | 双方向round-tripを実証後 |
| Managed AI | 月980円/年9,800円程度から検証 | 原価測定後、明示quota、BYOK併存。基本editorはsubscriptionに閉じない |

競合価格は変動するため、発売時に再調査する。監査時点では、Nola Premiumが月額/年額、iA WriterとScrivenerが成熟した買切り価格帯、TATEditorが無料で存在し、完成度の低い段階で成熟製品並みの価格を正当化しにくい。

### 14.2 試用の倫理

- 30「暦日」ではなく30「実使用日」の全機能試用を検討
- アカウント、カード登録なしで試せる
- 試用終了後も、作品を開く、読む、検索する、コピーする、標準形式へ書き出すことを許可
- ライセンスサーバが落ちても猶予期間中は編集可能
- offline activationまたは長いoffline graceを用意
- machine replacement/deactivationを利用者自身で行える
- 返金条件を購入前に明示し、破損・移行失敗には柔軟に対応
- major upgrade方針、対応OS、security fix期間を購入時に示す

創作ツールで「支払わないと自分の原稿を取り出せない」は、短期売上より長期信頼を大きく損なう。

### 14.3 直販先行

初期は次の理由で直販が妥当である。

- Sandbox外の既存設計を維持しやすい
- 買切り、試用、crossgrade、beta、返金を柔軟に運用できる
- 利用者と直接support関係を築ける
- 段階配信や緊急rollbackを設計できる

必要な構成:

- 製品site、download、動作環境、changelog、known issues
- Developer ID署名・公証済みDMG
- 署名付き自動更新
- Merchant of Recordまたは日本の税・VAT・請求を扱う決済
- license発行、offline grace、self-service reset
- 領収書、返金、invoice、サポート
- download checksumと真正性説明

Merchant of Recordの一例として[Paddle](https://www.paddle.com/pricing/)等があるが、手数料・審査・privacy・返金運用を比較する。MoRを使っても、製品のプライバシー、表示、サポート、安全性の責任は残る。

Mac App Storeは発見性と更新に利点があるが、Sandbox、App Review、App Storeの課金・privacy表示に合わせる必要がある。[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)を基に、直販版とは別のcapability、license、update構成として評価する。

### 14.4 価格検証

本文を収集せず、次を測る。

- landing pageからdownload
- 初回起動から最初の10文字、既存原稿import
- 1/7/30/90実使用日の再訪
- 試用→購入、5,800円 vs 7,800円
- 保存、open、recovery、exportの成功/失敗率
- support問い合わせの種類と解決時間
- refund理由、離脱理由
- 目標設定やAIの利用率より、再開と出力の成功を優先

価格A/Bは顧客群と提供内容を揃え、既存顧客へ不透明な差を作らない。early adopterには将来価格と更新権を明示する。

### 14.5 Unit economics

Managed AIを含める場合、editor本体と変動原価を同じ「無制限」価格へ混ぜない。

- 固定費: Apple Developer Program、商標/法務、site、mail、support、QA端末/VM、署名・release運用
- 変動費: 決済/MoR、返金、AI token、download/CDN、crash/support service
- 買切り売上から、major versionまでのsupportとsecurity update原価を先に確保
- AIはrequest種別ごとの原価、p95原価、retry、provider値上げ、為替を測る
- quotaを明示し、使い切った後も基本editorを制限しない
- BYOK/local modelを残し、managed AI停止が作品利用停止にならないようにする
- support ticket/購入者、refund、chargeback、update adoptionを価格判断へ入れる
- 教育/学生割引は本人確認コストとprivacyを含めて設計

損益分岐は「販売本数×手取り」だけでなく、1購入当たりのsupport時間、major update継続率、AI粗利を分けて計算する。

### 14.6 Go-to-market

- 2〜3個のpositioning文をlanding pageで検証し、waitlist登録理由と既存toolを確認する
- 最初は人数を追わず、12〜30人のdesign partnerに実作品で使ってもらう
- 「AI小説生成」ではなく、原稿主権、日本語IME、復旧、長編の再開をdemoする
- 既存TXT/Markdown/DOCXから10分で移れることをlanding pageで示す
- public sample `.novelpkg` と形式仕様、復旧方法を公開する
- 「なぜAIを完全OFFにできるか」を思想として説明する
- comparison pageは競合を貶さず、対象/非対象、local/cloud、縦書き、platform、価格を正確に比較する
- beta参加条件、データ取扱い、既知の制約、連絡方法を購入前に示す
- testimonialは原稿内容や未発表情報を求めず、workflowと信頼について許諾を取る
- migration guide、動画、keyboard cheat sheet、sampleを用意
- press kit、正確な機能表、対象/非対象FAQ、許諾済みscreenshot/testimonialを用意
- 流入channel別にlanding→download→first text/import→7日再開→購入を追い、CACとsupport負荷を比較する
- affiliate/referralは創作communityの信頼を損なわない開示を必須にする
- launch後もroadmap投票だけで優先度を決めず、failure/supportと継続taskを優先する

## 15. 法務、プライバシー、サポート、運用

### 15.1 課金前に公開するもの

- 利用規約/EULA
- プライバシーポリシー
- 特定商取引法に基づく表示
- 価格、支払方法、提供時期、追加費用、動作環境
- 試用、返金、解約、major upgrade方針
- AI事業者/subprocessors、送信範囲、保存期間、削除方法
- support窓口、対応時間、対象version
- security contactと脆弱性報告方針
- backup、recovery、migration、service終了時のデータ救出
- third-party licenses/notices
- accessibility statement
- release notes、known issues、status/incident告知方法

日本の通信販売表示は、事業者情報、価格、支払時期/方法、引渡し、返品等の表示が論点になる。消費者庁の[通信販売の広告表示](https://www.no-trouble.caa.go.jp/what/mailorder/advertising.php)と[最終確認画面等のガイド](https://www.no-trouble.caa.go.jp/what/mailorder/guidelines.html)を参照し、専門家確認を受ける。

### 15.2 プライバシー

原稿には、公開前作品、実在人物情報、取材資料、契約上の秘密が入り得る。「氏名やメールを集めないから低リスク」と考えない。

- 既定ではanalyticsなし、または明示opt-in
- 本文、タイトル、人物名、ファイル名、絶対パスをtelemetryへ送らない
- eventを送る場合は粗い機能利用とerror codeに限定し、local previewを用意
- crash reportは本文bufferやwindow titleをredactし、送信前に確認可能にする
- privacy policyへAI/決済/update/crash providerを列挙
- 保存地域、保持期間、削除、問い合わせ手段を明示
- provider変更時にpolicyとapp表示を更新
- accountを作るならapp内削除とdata exportを用意
- 子ども、共同端末、学校利用を想定するなら別途評価

App Storeへ出す場合、App Privacy回答はthird-party SDKやAI providerも含めて整合させる。[Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)を参照。

### 15.3 IPと公開repo

公開repoにライセンスがない状態は、通常、第三者へ利用・改変・再配布の許諾を与えていない。これは著作権者自身の販売権が曖昧という意味ではない。一方、商用化には全commit、素材、依存物の権利chain確認が必要であり、今後外部contributionを受けるなら、その商用利用条件を先に定める必要がある。

決めること:

- sourceを非公開化するproprietary productか
- editor/coreをOSS、同期/AI/配布を商用にするopen-coreか
- 全体OSSでsupport/managed serviceを販売するか
- contributionを受けるならCLA/DCOのどちらか
- dependency、font、icon、generated assetの商用license inventory
- AI生成code/artを含む場合のreview記録
- 新名称、logo、拡張子、domainの権利確保

ライセンスを後付けする前に、全commitの著作権者と素材由来を確認する。

### 15.4 サポート

サポートは発売後に足す機能ではない。

- App内「ヘルプ」「診断情報を表示」「問い合わせ」「既知の問題」
- version/build、OS、architecture、format version、直近error codeを集めるdiagnostic bundle
- 本文・タイトル・パスは既定で除外し、含む場合は個別選択
- データ破損用の優先窓口と、原本を触らない回復手順
- FAQ: 開けない、保存できない、移動した、更新できない、license、AI課金、書出し
- support response目標、休日、対応言語、対象version
- incident severity、status update、hotfix、rollback runbook
- 終了/買収/サービス停止時もlocal appとexportを維持する方針

### 15.5 Release運用

- versioningと`.novelpkg` format versionを分離
- backward/forward compatibility matrixを公開
- migration前backupとrollback可否をrelease noteへ記載
- beta/stable channelを分け、作品単位でchannelを混ぜた時の警告
- staged rollout、crash/error監視、kill switchは本文を送らず実現
- signing/notarization/update keysを分離し、rotation手順を用意
- archive、dSYM、source revision、dependency lock、notary resultを保管
- reproducible release checklistを二者確認できる形にする
- old vulnerable versionへの対応と最低support期間を定める
- emergency updateでもpackage migrationを無闇に含めない

### 15.6 単独開発の事業継続

作者は数年単位で作品を預ける。開発者が作業できない期間も含め、次をrunbook化する。

- source repo、release archive、notarization記録、website、domain、mail、決済accountの復旧手順
- signing/update keyの暗号化backup、rotation、紛失時の告知。秘密鍵そのものをrepoへ入れない
- 二要素認証のrecovery codeと緊急連絡先
- 病欠/休止時のsupport自動応答、重大データ事故の優先連絡、返金判断
- 決済/AI/update provider障害時にもeditorとexportが動くdegraded mode
- 事業終了時の最終offline build、license解除、export、format仕様、download mirror、告知期間
- domainや証明書失効後も既存appが原稿を開ける設計
- 個人事業から法人化/譲渡する場合のprivacy通知と契約移行
- support不能なOS/versionを終了する基準と長期保存用の救出版

## 16. 「神は細部に宿る」設計

### 16.1 細部の原則

楽しさは紙吹雪、連続日数、音ではなく、「アプリが自分の昨日を覚えている」「消えないと分かる」「考えていたものが自然につながる」ことで生まれる。すべて任意、静か、Reduced Motion対応、色だけに依存しないことを条件にする。

### 16.2 戻ってくる瞬間

- 前回の作品・話・カーソル・選択・スクロール・sidebar幅まで正確に戻す
- 「昨日ここまで」の一行と前後2段落を、本文へ混入しない小さなbookmarkとして出す
- 直近に開いた人物/資料も「参照棚」に復元する
- 前回終了時に保存できなかった場合、通常画面より先にRecoveryを出す
- 朝・昼・夜の挨拶ではなく、作品名と「続きを書く」だけを静かに示す
- 長く空いた作品には罪悪感を刺激せず「またここから始められます」と表示
- 最後の編集から構造が外部変更された時は、戻る位置を推測せず選択させる

### 16.3 書いている瞬間

- 保存成功時、statusの小さなink dotが一度だけ落ち着く。音もtoastも出さない
- 保存statusをクリックすると、最終成功時刻、場所、直近backup、健全性を見られる
- `「」`、`『』`、`（）`で選択範囲を一回のUndoで包む
- `…`を入力した時、作品ruleに応じて`……`候補を控えめに出す
- 段落を削った時、「切り抜き箱へ送る」をUndo toast内に出す
- Typewriter modeで現在行を固定するが、scrollしたら自然に追従を一時解除する
- Focus modeの薄れ方を文/段落/話から選べる
- 目標達成時、Outlineの話へ紙の栞がそっと現れる。紙吹雪・効果音は既定OFF
- 夜のthemeでは、達成時に机上灯の色温度がわずかに変わる。演出OFFあり
- 文字数は常時競わせず、選択またはstatus click時に必要な粒度だけ展開
- paste時にsmart quote、全半角、投稿記法の変化を適用前previewできる
- 巨大pasteの直前に自動安全版を作り、UIを固めない

### 16.4 迷った瞬間

- `Cmd+P`で章、話、人物、世界観、資料、commandを一つの検索窓から開く
- Spaceで人物カード、ノート、資料を一時previewし、放す/閉じると本文へ戻る
- 人物名にpointerを置くと、一人称、関係、直近登場を小さく表示。本文選択を奪わない
- 章話のbreadcrumbをclickすると、その階層の兄弟だけを素早く選べる
- 「戻る/進む」は単なるsectionではなく、本文の選択位置まで戻す
- しおりへ色だけでなく名前を付ける。「あとで削る」「会話確認」等は個人presetにできる
- 参照棚へ最大3件を固定し、本文と同時に見る。狭いwindowではpopoverへ退避
- 書けない時のpromptをランダム表示せず、作者が保存した問いやカードから選ぶ

### 16.5 構成がつながる瞬間

- PlotCardを話へdragするとコピーでなくlinkされ、二重管理を避ける
- 伏線を選ぶと、張った文→中間の手掛かり→回収文が細い一本の糸になる
- 人物相関線を選ぶと、関係を示す本文箇所だけをtimelineに並べる
- 話の長さを派手なgraphではなくOutline端の静かな「温度」として示す
- 章ごとのdialogue比率、scene長、POVを鳥瞰できるが、良否を採点しない
- timeline上で「この人物はまだこの事実を知らない」を視覚化する
- ノートを本文へdragすると本文リンクまたは参照だけを選べる
- 人物・設定変更時、影響しそうな本文を「修正」ではなくreview候補にする
- 未回収伏線を赤い警告にせず、完稿preflightで確認項目として出す

### 16.6 守られていると感じる瞬間

- window titleの小さな状態dotが未保存/保存中/失敗を形とtextで示す
- 大規模削除、import、全置換、migration前に自動で「安全版」を作る
- Snapshotへ名前、短いmemo、当時の作品冒頭でない安全な抜粋を付ける
- 「原稿はこのMacから送信されていません」を、AI完全OFF作品で確認できる
- package健全性を必要時に実行し、`検査した日時 / 問題 / backup`を表示
- 外付けdisk切断時は入力を失わず、Recovery Storeに退避したことを説明する
- Save As後、「元の作品」と「新しい作品」のどちらを編集中か明瞭にする
- update前に作品を検証・backupし、完了後に開けることを確認する
- license/試用終了時も「書出しはいつでもできます」と明記する

### 16.7 仕上げる瞬間

- Export preflightで空title、壊れたruby、未対応文字、未保存変更を一画面に出す
- 投稿先ごとの変換箇所を紙面preview上でtap/clickすると原稿へ戻る
- 書き出し完了後に「開く / Finderで表示 / コピー / もう一度」を出す
- 達成演出より「何文字・何話・どのversionを書き出したか」の確かなreceiptを残す
- 完稿版を「封印」しread-only milestoneにできる。編集再開時はbranch/snapshotを作る
- End-of-sessionで今日の追加/削除をdiffとして眺められるが、共有を促さない
- シリーズの巻を終えた時、次巻へ人物/世界観をコピーでなく共有する設計を将来検討

### 16.8 マイクロインタラクションの禁止事項

- 入力ごとの音、強いhaptic、紙吹雪を既定にしない
- 執筆日数を途切れさせて罪悪感を与えない
- AI creditやupgrade bannerを本文近くに出さない
- 保存成功のたびにtoastを出さない
- 「100点」「完成度80%」など作品を採点しない
- 空状態へ大量の説明やsample dataを勝手に入れない
- animationでcursorや本文位置を動かさない
- color themeを可読性より優先しない

## 17. 推奨ロードマップ

現行のPhase 6をそのまま進めず、商品gateへ並べ替える。各gateは期間ではなく受入条件で閉じる。

### Gate A: Product Contract

- 一次ターゲット、非対象、JTBD、中心約束を決定
- 名称clearanceと改名判断
- proprietary/OSS/open-core方針
- 直販/MAS、買切り/subscription、試用・救出方針
- D-011、D-012、D-037、AI優先順を商品判断として再審査
- 12〜16人の対象作者へproblem interviewとprototype test

**終了条件:** 誰がなぜ今の道具から乗り換え、何には対応しないかを一枚で説明できる。

### Gate B: Data Safety Foundation

- 起動state、Recovery Center、recent path保護
- `.novelpkg` validator、W0 fixture、read-only recovery
- invalid UTF-8、orphan、duplicate ID、symlink、migration、外部変更対策
- Cmd+S、save failure recovery、終了時選択
- 外部backup、自動snapshot、ゴミ箱、構造Undo
- 障害注入テスト

**終了条件:** 想定障害で無通知のデータ置換・救出データ消失が0件。原本を変更せず修復コピーを作れる。

### Gate C: Release Trust

- AppIcon、名称、bundle ID、UTType、document association
- Hardened Runtime、Developer ID、公証、stapled DMG
- 署名付きupdate、rollback、versioning、archive/dSYM
- Welcome、Recent、Import、Help、diagnostics
- Privacy/EULA/特商法/返金/support/security文書
- Light/Dark、VoiceOver、keyboard、Reduce Motion

**終了条件:** clean Macでdownload→install→open/import→write→update→export→uninstallまでsupportなしで完遂できる。

### Gate D: Writing Continuity

- 話ごとのcursor/scroll/Undo、戻る/進む、参照棚
- 全稿検索・置換、Quick Open、command palette
- 日本語local校正、切り抜き箱、diff/history
- 長文performance gate
- 投稿向けcopy/preview

**終了条件:** 再起動後5秒程度で前回位置から再開でき、30万字級の実作品で主要操作に実用上の停止がない。

### Gate E: Paid Beta

- 30実使用日試用、買切りlicense、offline grace、救出保証
- 価格・返金・support運用
- beta/stable update channel
- 対象作者による実作品30日運用
- save/open/export successとsupport loadを観測

**終了条件:** データ安全P0が0、主要task成功率、継続利用、support responseが設定基準を満たす。未完成範囲を購入前に開示できる。

### Gate F: Japanese Delivery 1.0

- DOCX import/export
- PDFまたは選定segmentに必要な提出形式
- EPUB metadata、cover、ruby、epubcheck、実reader
- 投稿先profile、preflight、export receipt
- 縦書きpreview/outputの需要判断とD-012の更新

**終了条件:** 対象顧客が外部editorへ原稿を移さず、執筆→推敲→提出/投稿の中心loopを完遂できる。

### Gate G: Integrated Story Intelligence

- Episode/PlotCard/人物/伏線/世界観のdeep link
- timeline、関係、knowledge state
- local rule review
- optional AIの送信preview、根拠、diff、Undo、privacy

**終了条件:** AIなしでも統合modelに価値があり、AI利用者が送信内容と変更内容を正しく説明できる。

### Gate H: Platform Expansion

- 有償betaデータでWindows/iPad/縦書きEditor/共同機能のどれを選ぶか決める
- WindowsはW0→W1→双方向round-tripを崩さない
- Windows版はMSIX、署名、update、アクセシビリティをMac版と同じ商品gateで評価
- iPadは同期/競合/入力/資料のproduct contractが成立してから

**終了条件:** 「市場が広そう」ではなく、既存顧客の具体的な失注・利用要求で投資を説明できる。

## 18. 検証計画

### 18.1 顧客調査

4群×3〜4人、計12〜16人を最低単位とする。

- Mac中心のWeb連載作者
- 公募/商業志望の長編作者
- 設定・構成重視の作者
- クラウド/生成AIを避けたい作者

聞く内容は「欲しい機能」より、直近作品で実際に起きた事故、道具の組合せ、移行、推敲、提出、支払いである。prototypeでは既存原稿を使ってもらい、機密原稿の提供を要求しない。

### 18.2 Task benchmark

- 初回起動→最初の10文字: 中央値60秒以内
- 既存TXT/Markdown→章話import: 成功率90%以上、原本変更0
- 再起動→前回位置で入力: 5秒程度、位置復元100%
- 人物/資料参照→本文へ戻る: cursor/scroll/Undo喪失0
- 全稿検索→置換preview→Undo: 成功率95%以上
- 保存障害→recovery: 無通知の置換0、原本保持100%
- export→外部アプリで開く: 対象profile成功率95%以上
- VoiceOver/keyboard-only主要flow: 完遂100%
- update/rollback: 作品破損0、旧版互換違反を明示
- AI送信前: 利用者が送信範囲、provider、費用を説明できる率90%以上

### 18.3 北極星とguardrail

北極星候補は「本文を何文字書いたか」ではなく、**週内に安全に再開し、少なくとも一回保存/出力まで完遂した作品数**とする。

Guardrail:

- data loss/recovery incident
- open/save/export failure
- crash-free session
- support first response / resolution
- refundと理由
- update failure/rollback
- AI誤送信・想定外provider・費用超過
- accessibility task failure

本文、作品名、登場人物名、ファイル名をanalyticsで収集しない。可能なら集計をlocalで見せ、送信はopt-inにする。

## 19. 1.0完了の定義

次を全て満たすまで「正式版」「商用品質」「Windows互換」「出版可能EPUB」等を名乗らない。

- 名称、IP、license、規約、privacy、特商法、supportが確定
- P0一覧が0件
- clean Macで署名・公証・update・rollbackを確認
- `.novelpkg` validator、recovery、external backup、migration、W0 fixtureが完了
- invalid UTF-8、orphan、duplicate、symlink、disk full、move/conflictで原稿を黙って失わない
- Welcome、Recent、Import、Cmd+S、全稿検索置換、history、export preflightが動く
- 主要flowがVoiceOverとkeyboard-onlyで完遂
- Light/Dark/contrast/reduced motionを実機確認
- 30万〜100万字級fixtureで入力・検索・保存・出力の目標を満たす
- release artifact自体にE2Eを行う
- 有償betaの実作品運用で重大事故0、support体制が持続可能
- 試用/解約/障害後も原稿を救出できる
- AIを使う場合は完全OFF、送信preview、provider固定、費用上限、diff、Undo、削除がある

## 20. 最終提言

NovelWriterを商業化するうえで、最大の機会は「AIを載せた多機能エディタ」になることではない。**昨日の続きを、昨日の場所から、異常時にも黙って置き換えず、救出可能な形で始められること**である。

技術基盤の良さは、この約束を実現するために使う。次の実装PhaseはAIではなく、Product Contract、Data Safety Foundation、Release Trust、Writing Continuityに置き換えるべきである。その後、日本語の投稿・提出までを一続きにし、人物・設定・伏線を本文の根拠箇所へ結ぶ。AIはその構造を利用して、必要な作者だけに根拠付きレビューを提供する。

機能を増やす前に、名前、対象、失敗時の挙動、原稿の所有権、出口を決める。細部の楽しさは、その信頼の上にだけ成立する。

## 付録A: 実行バックログ

以下は重複を恐れず、実装計画へ転記しやすい粒度で列挙した。チェックは監査時点では未完了を意味する。

### A.1 商品・ブランド

- [ ] 一次personaと非対象personaを決定
- [ ] JTBDと一文のvalue propositionを決定
- [ ] 既存`novelWriter`との名称衝突を法務・検索・ストアで調査
- [ ] 改名/継続のgo/no-goを記録
- [ ] domain、SNS、store、GitHub handleを確保
- [ ] AppIcon、wordmark、16px〜1024pxの識別性を検証
- [ ] bundle ID、UTType、package拡張子の移行方針を決定
- [ ] proprietary/OSS/open-coreを決定
- [ ] LICENSE、third-party notices、contribution条件を整備
- [ ] pricing、trial、upgrade、refund、offline graceを検証

### A.2 起動・作品ライフサイクル

- [ ] `launching/ready/recovery` stateを導入
- [ ] loading中のEditorを編集不可にする
- [ ] 読込失敗時に新規作品へ自動fallbackしない
- [ ] failure時にrecent pathを書き換えない
- [ ] Welcome/Recent/New/Open/Import/Sampleを用意
- [ ] 新規作成で作品名と保存先を選ぶ
- [ ] Open Recentとmissing item cleanupを提供
- [ ] Finder double-click/Open Withを提供
- [ ] window represented URL、作品名、保存状態を提供
- [ ] move/rename/delete/external modificationを検出
- [ ] 複数window/単一windowの将来contractを再評価

### A.3 保存・復旧

- [ ] Cmd+Sを`saveNow()`へ明示結線
- [ ] save stateに最終成功時刻とerror codeを持つ
- [ ] 保存失敗のretry/save as/recovery exportを提供
- [ ] 終了時失敗にretry/save as/cancelを提供
- [ ] invalid UTF-8を空本文にしない
- [ ] orphanをload→save→loadで保全
- [ ] read-only recovery modeを実装
- [ ] 修復コピーと診断reportを出力
- [ ] duplicate IDと不正参照を検出
- [ ] symlink/path traversal/reparseを拒否
- [ ] case/Unicode/Windows予約名衝突を検出
- [ ] component/full path/件数/容量上限を決定
- [ ] 短い固定prefixのworking packageへ変更
- [ ] commit前read-back/inventory検証を行う
- [ ] migration前に外部backupを作る
- [ ] file identity/mtime/hash conflictを検出
- [ ] iCloud/Dropbox conflicted copyの方針を決定
- [ ] network/external volume切断時のRecovery Storeを用意
- [ ] Save As中の継続編集を正しく追保存・通知
- [ ] snapshot作成を原子的にする
- [ ] snapshot timestampを論理名から読む
- [ ] snapshot名/memo/diff/部分復元を提供
- [ ] 自動世代・容量・固定版・削除UIを提供
- [ ] package外backupと復元演習を提供
- [ ] 構造操作Undoまたはゴミ箱を提供
- [ ] 大規模操作前の自動安全版を作る

### A.4 エディタ・検索・推敲

- [ ] 話ごとのcursor/selection/scrollを保持
- [ ] 話切替後もUndoを保つ設計を決める
- [ ] 全稿検索と結果一覧を実装
- [ ] scope/filter/正規表現を実装
- [ ] replace previewと一括Undoを実装
- [ ] Unicode/全半角/かな差の検索optionを検討
- [ ] Quick Open/command paletteを提供
- [ ] 戻る/進むを本文位置まで保持
- [ ] spelling/grammar/text replacementを設定化
- [ ] 日本語記号入力支援を個別設定化
- [ ] local校正ruleと辞書/ignoreを提供
- [ ] typewriter/focus/full-screenを提供
- [ ] 話の分割/結合/複製を提供
- [ ] 切り抜き箱を提供
- [ ] 選択/話/章/全稿の文字数を定義
- [ ] 原稿用紙換算と投稿先上限を提供
- [ ] 今日の追加/削除/純増をlocal計算
- [ ] 目標と締切を任意で提供

### A.5 構造・資料

- [ ] PlotCardとEpisodeの関係を決定
- [ ] card status/tag/POV/location/time/castを任意追加
- [ ] board/outline/timeline/tableを同一dataから表示
- [ ] 人物の別名/相手別呼称/関係/arcを追加
- [ ] 名前検出の候補/手動補正/ignoreを追加
- [ ] 登場箇所を本文rangeへdeep link
- [ ] 伏線の提示/回収を本文rangeへdeep link
- [ ] 伏線の複数hint/複数resolutionを扱う
- [ ] WorldNoteにtag/backlink/internal linkを追加
- [ ] ノート種類/templateを任意提供
- [ ] 本文と参照情報のsplit/参照棚を提供
- [ ] 資料Quick Look/open/thumbnailを提供
- [ ] 資料tag/memo/関連linkを提供
- [ ] 大容量/危険形式/重複を扱う
- [ ] 作品/series間の設定共有はcopyとlinkを区別

### A.6 Import/Export

- [ ] TXT encoding/line break/import preview
- [ ] Markdown heading mapping/import preview
- [ ] DOCX importとloss report
- [ ] importは必ず新規作品/原本非変更
- [ ] 専用Export sheetへ統合
- [ ] 出力対象、見出し、空行、metadata profileを保存
- [ ] TXT/Markdown previewと投稿先変換
- [ ] Kakuyomu/Narou等の記法profileを検証
- [ ] DOCX exportとWord/Pages相互確認
- [ ] PDFの対象segment、横/縦、原稿用紙要件を再決定
- [ ] EPUB author/cover/description/rights/ruby/accessibilityを追加
- [ ] epubcheck、Apple Books、Kindle Previewerをgate化
- [ ] export preflightとwarning-to-source jumpを提供
- [ ] 成功receiptとFinder/Open/Copy導線を提供
- [ ] 取消、overwrite、atomicity、容量不足をE2E確認

### A.7 UI・アクセシビリティ

- [ ] dark強制を撤廃しSystem/Light/Darkを提供
- [ ] unfinished AI/dummy statusを非表示
- [ ] App設定と作品設定を分離
- [ ] toolbarのlabel/overflow/keyboardを整理
- [ ] Outline検索を常に発見可能にする
- [ ] narrow window/minimum size/split collapseをQA
- [ ] custom color contrastとresetを提供
- [ ] font sizeの安全範囲を再検討
- [ ] VoiceOverで主要flowを完遂
- [ ] Full Keyboard Accessで主要flowを完遂
- [ ] drag操作へkeyboard/menu代替を提供
- [ ] Increase Contrast/Reduce TransparencyをQA
- [ ] Reduce Motionでanimationを抑制
- [ ] Differentiate Without ColorをQA
- [ ] save/search/export完了を適切にAX announce
- [ ] 日本語/英語の語彙とspace表記を統一
- [ ] Empty stateへ次の主操作を一つ置く
- [ ] error copyを「事実/安全/次の操作」で統一

### A.8 AI

- [ ] AIなしの中心loopを先に完成
- [ ] AI完全OFF/作品単位OFF/UI非表示を提供
- [ ] API keyをKeychainへ保存
- [ ] provider/model/ZDR/fallbackを明示・固定
- [ ] 送信対象range/contextをpreview
- [ ] token/費用見積りと上限/cancelを提供
- [ ] 本文へ自動上書きせずdiff proposalにする
- [ ] apply/partial apply/reject/Undoを提供
- [ ] 根拠箇所とconfidenceを表示
- [ ] AI履歴削除/exportを提供
- [ ] model/provider変更時の再同意を定義
- [ ] response中断/rate limit/outageを安全に扱う
- [ ] 本文/プロンプトをdiagnostic logへ出さない
- [ ] AI利用なしを確認できるlocal statusを提供
- [ ] 著作権・正確性を保証しない文言を整備

### A.9 配布・品質・運用

- [ ] Hardened Runtimeを有効化
- [ ] Developer ID署名、公証、stapleを自動化
- [ ] Gatekeeper clean Mac testを追加
- [ ] AppIcon、copyright、development regionを整備
- [ ] UTType/Document Types/package iconを整備
- [ ] signed auto-update、staged rollout、rollbackを実装
- [ ] Release archive/dSYM/notary/checksumを保管
- [ ] release artifact E2Eを追加
- [ ] macOS/CPU/IME matrixを決定
- [ ] XCUITest/Accessibility Inspector gateを追加
- [ ] ENOSPC/kill/lock/move/conflict障害注入を追加
- [ ] 10万/100万/300万字benchmarkを追加
- [ ] SwiftLint warningを0にし、NovelAppも対象化
- [ ] EPUB実reader gateを追加
- [ ] diagnostic bundle、crash、known issuesを整備
- [ ] Security contact/incident/hotfix runbookを整備
- [ ] Privacy/EULA/特商法/refund/supportを公開
- [ ] App/format/version compatibility matrixを公開
- [ ] trial/license/offline grace/rescueをE2E確認
- [ ] 30日実作品betaとgo/no-go reviewを実施

## 付録B: 主なローカル根拠

行番号は監査対象commit `462233d`時点。否定的所見だけでなく、既にある保護も含めた。

| 所見 | 根拠 |
|---|---|
| 編集可能placeholderを表示後に非同期bootstrap | [NovelWriterApp.swift L47-L60](../NovelApp/NovelWriterApp.swift#L47-L60)、[AppState.swift L147-L153](../NovelApp/AppState.swift#L147-L153) |
| 前回作品のload失敗後に新規作成・recent更新 | [AppState.swift L175-L236](../NovelApp/AppState.swift#L175-L236) |
| Episode本文/メモの読込失敗を空へ変換 | [NovelpkgRepository.swift L104-L127](../NovelKit/Sources/NovelStorage/NovelpkgRepository.swift#L104-L127) |
| WorldNote本文の読込失敗を空へ変換 | [NovelpkgRepository+World.swift L20-L24](../NovelKit/Sources/NovelStorage/NovelpkgRepository+World.swift#L20-L24) |
| 保存時に既知directoryを再構築し、未知root itemだけをcopy | [NovelpkgRepository.swift L236-L268](../NovelKit/Sources/NovelStorage/NovelpkgRepository.swift#L236-L268)、[L365-L399](../NovelKit/Sources/NovelStorage/NovelpkgRepository.swift#L365-L399) |
| 現行failure testはorphanをload直後に残す確認まで | [NovelpkgRepositoryFailureTests.swift L34-L68](../NovelKit/Tests/NovelStorageTests/NovelpkgRepositoryFailureTests.swift#L34-L68) |
| Snapshot作成は最終名へ直接書き、日時表示はFS属性由来 | [NovelpkgRepository+Snapshots.swift L33-L67](../NovelKit/Sources/NovelStorage/NovelpkgRepository+Snapshots.swift#L33-L67)、[L70-L122](../NovelKit/Sources/NovelStorage/NovelpkgRepository+Snapshots.swift#L70-L122) |
| Snapshot復元はworking packageを使う | [NovelpkgRepository+Snapshots.swift L125-L140](../NovelKit/Sources/NovelStorage/NovelpkgRepository+Snapshots.swift#L125-L140)以降 |
| Save As後の追保存結果を呼出元へ返さない | [AppState.swift L330-L336](../NovelApp/AppState.swift#L330-L336) |
| Episode切替時に本文を差し替え、Undoをclear | [MacTextAdapter.swift L79-L94](../NovelKit/Sources/EditorKit/Platform/macOS/MacTextAdapter.swift#L79-L94) |
| macOS標準の補正/検査を一律OFF | [MacTextAdapter.swift L120-L143](../NovelKit/Sources/EditorKit/Platform/macOS/MacTextAdapter.swift#L120-L143) |
| 毎変更で全文Stringをmodelへ通知 | [MacTextAdapter.swift L210-L242](../NovelKit/Sources/EditorKit/Platform/macOS/MacTextAdapter.swift#L210-L242) |
| `.novelpkg`のUTType/Document Typesを意図的に未宣言 | [DocumentPanelPresenter.swift L14-L18](../NovelApp/DocumentPanelPresenter.swift#L14-L18) |
| dark外観強制 | [NovelWorkbenchView.swift L30-L37](../NovelApp/NovelWorkbenchView.swift#L30-L37) |
| 未接続AI panelとdummy status | [NovelWorkbenchView.swift L465-L515](../NovelApp/NovelWorkbenchView.swift#L465-L515)、[L547-L649](../NovelApp/NovelWorkbenchView.swift#L547-L649) |
| Hardened Runtime無効、AppIcon/Document Type設定なし | [project.yml L47-L67](../project.yml#L47-L67) |
| W0未完了とMac writerの未保証を明記 | [CROSS_PLATFORM.md L1-L5](CROSS_PLATFORM.md#L1-L5)、[L104-L127](CROSS_PLATFORM.md#L104-L127) |

## 付録C: 参照した主な公開資料

### 配布・プラットフォーム

- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple: Preparing your app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution)
- [Apple: Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)
- [Apple: App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Apple: App privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)

### 国内制度・AI

- [消費者庁: 通信販売の広告表示](https://www.no-trouble.caa.go.jp/what/mailorder/advertising.php)
- [消費者庁: 通信販売の申込み段階における表示ガイドライン](https://www.no-trouble.caa.go.jp/what/mailorder/guidelines.html)
- [個人情報保護委員会: 生成AIサービスの利用に関する注意喚起](https://www.ppc.go.jp/news/careful_information/230602_AI_utilize_alert/)
- [個人情報保護委員会: 外国にある第三者への提供](https://www.ppc.go.jp/personalinfo/legal/guidelines_offshore/)
- [文化庁: AIと著作権](https://www.bunka.go.jp/seisaku/chosakuken/aiandcopyright.html)
- [OpenRouter: Provider Data Collection](https://openrouter.ai/docs/guides/privacy/provider-logging/)

### 競合・市場

- [novelWriter](https://novelwriter.io/)
- [Nola](https://apps.apple.com/jp/app/nola-%E5%B0%8F%E8%AA%AC%E3%82%92%E6%9B%B8%E3%81%8F%E4%BA%BA%E3%81%AE%E3%81%9F%E3%82%81%E3%81%AE%E5%9F%B7%E7%AD%86%E3%82%A8%E3%83%87%E3%82%A3%E3%82%BF%E3%83%84%E3%83%BC%E3%83%AB/id1468307521)
- [TATEditor](https://tateditor.app/)
- [Novel Airline](https://apps.apple.com/jp/app/novel-airline/id1499642698)
- [Story Plotter](https://apps.apple.com/jp/app/%E3%82%B9%E3%83%88%E3%83%BC%E3%83%AA%E3%83%BC%E3%83%97%E3%83%AD%E3%83%83%E3%82%BF%E3%83%BC-%E3%83%8D%E3%82%BF-%E3%81%8B%E3%82%89-%E3%83%97%E3%83%AD%E3%83%83%E3%83%88-%E3%82%92/id1491980862)
- [Core](https://corewrite.app/en/)
- [Scrivener](https://www.literatureandlatte.com/scrivener/overview)
- [iA Writer Authorship](https://ia.net/ja/writer/support/editor/authorship)
- [Ulysses](https://help.ulysses.app/en_US/getting-started/details-and-tips)
- [Storyist](https://storyist.com/mac/)
- [Plottr pricing](https://plottr.com/pricing/)
- [Novelcrafter](https://www.novelcrafter.com/)
- [Sudowrite pricing](https://sudowrite.com/pricing)
- [Atticus](https://www.atticus.io/)
