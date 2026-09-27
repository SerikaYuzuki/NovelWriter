# macOSの滑らかなカーソル（2026-09-26）

## 採用した仕様

所有者が独立した試作版で入力・改行・行削除・上下移動を試し、通常版への組み込みを依頼した。macOSの執筆設定「滑らかなカーソル」は既定ONで、端末のUserDefaultsへ保存する。OFFにするとその場で標準表示へ戻る。iOSへのアニメーション追加は行わない。

`NSTextInsertionIndicator`の標準の点滅と入力言語表示を使い、同じ行内の短い移動と隣の表示行への上下移動を90msで補間する。改行、行頭のBackspace、上下キー、折返し、IME中の未確定文字の増減に共通の判定を使う。入力操作が入れ子になっても、字下げpluginを含む標準処理の完了位置へ一度だけ動かす。追加入力では現在の表示位置から追従し直し、移動をキューに積まない。

マウス操作・スクロール・複数行のジャンプ・話のinstallでは瞬時に配置する。範囲選択、複数カーソル、フォーカス喪失、読み取り専用、macOSの「視差効果を減らす」では標準表示に戻す。

## 本文・IME・保存の境界

本文・選択範囲・marked text・Undo・IME候補ウインドウは標準のTextKit 2に任せる。実際の入力位置は即座に更新し、表示用の縦線だけを短時間で追従させる。非公開のsubview探索、method swizzling、TextKit 1へのfallback、公開APIへのネイティブtext viewの露出は行わない。

`EditorConfiguration.animatesCaret`は表示用カーソルの設定であり、フォントや本文属性の変更とは別に適用する。IME中も切り替え可能で、marked textを確定させない。切り替えだけではtextStorage属性を再適用せず、選択・スクロール・Undoを保持する。フォント等の設定変更は従来どおりIME確定後まで保留する。

候補へ返す`firstRect`は変更しない。候補は実際の入力位置に出るため、表示用カーソルが追従する90msの間は短い位置差が生じ得る。

## 実装の入口

- [表示用text view](../NovelKit/Sources/EditorKit/Platform/macOS/AnimatedCaretTextView.swift)
- [移動範囲の判定](../NovelKit/Sources/EditorKit/Rules/CaretMotionPolicy.swift)
- [macOS adapter](../NovelKit/Sources/EditorKit/Platform/macOS/MacTextAdapter.swift)と[値型の設定](../NovelKit/Sources/EditorKit/Core/EditorConfiguration.swift)
- [端末設定と画面](../NovelApp/Features/Writing/EditorSettings.swift)
- [入力・Undo・候補座標のテスト](../Experiments/CaretLabTests/CaretMotionTests.swift)と[設定の回帰テスト](../NovelKit/Tests/EditorKitTests/MacCaretConfigurationTests.swift)

独立アプリ「ふみにわ カーソル試作」は通常版と同じEditorKit productをリンクする検証用画面として残す。専用のnative view factoryや設定通知は持たず、通常版と同じ設定APIで切り替える。試し書きの保存先は検証版専用のUserDefaultsで、作品DB・認証・同期へ接続しない。

## 検証と稼働反映

検証段階は中ぐらい。通常EditorKitの138テスト、同じEditorKit productを使う検証アプリの11テスト、通常アプリの設定・保存位置に関する16テストが成功した。保存位置テストではアニメーションが有効になるkey状態を与え、同期あり／なし、範囲選択、IME中／確定後、繰り返し保存で選択・スクロール・Undoを確認した。iOS向けNovelKitのコンパイルと、署名付きmacOS Releaseビルドも成功した。

入力テストは実際のTextKit 2・marked text・`insertText`・Undoを使う。バックグラウンドのテストではウインドウのkey状態だけを固定し、実際のフォーカスは実画面で別に確認した。通常版で執筆設定のON/OFF、既存作品の表示、上下キー、⌘S後の本文保持と本文へのフォーカスを確認した。実原稿への試験用文字の挿入はしていない。

現在のアプリとSQLiteを退避し、コピーしたDBの整合性と同じ署名Teamを確認して通常版を更新した。退避先は`~/Library/Application Support/FUMINIWA/DeploymentBackups/20260926-173137-smooth-caret/`。稼働中の実行ファイルSHA256は`37ce5f02c243541622155537cbf77a0908ee8d3040e6f533f18c1184c43ba38e`。

全IME・かな入力・音声入力・VoiceOver・画面間移動・長時間利用の受入は未実施。初回の試作では、このMacの日本語ライブ変換・候補送り・確定・取消を実キーボードで確認した。候補へ返す座標が変わらないことは自動テストで確認しているが、別のシステムウインドウに出る候補一覧全体の位置はアプリ単体の画面取得では確認できていない。

参照：[NSTextInsertionIndicator](https://developer.apple.com/documentation/appkit/nstextinsertionindicator)、[標準カーソルの独自ビューへの組込み](https://developer.apple.com/documentation/appkit/adopting-the-system-text-cursor-in-custom-text-views)、[NSTextView](https://developer.apple.com/documentation/appkit/nstextview)。
