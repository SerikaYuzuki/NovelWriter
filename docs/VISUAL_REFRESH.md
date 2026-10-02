# 画面刷新の受入確認の残件

棚・作品ホーム・人物・世界観・プロット／伏線・切り抜きの実装規約は[STYLE](STYLE.md)へ集約した。

- macOSのネイティブウインドウ撮影と目視受入。隔離したDebug-TestでのView描画は取得できるが、この作業環境では外部のウインドウ撮影が黒い画像になる。View描画をnative toolbar／materialの受入成功とは扱わない。作品棚の表紙／一覧（700pt含む）、人物、世界観、プロット／伏線、切り抜きをLight／Darkで再確認する。
- `./Scripts/check.sh`全工程の完走。実行環境の`SwiftMacros.TaskLocalMacro`起動時に`sandbox_apply: Operation not permitted`で停止する。個別のアプリテスト・lintの結果と区別する。

画面取得は`VisualRefreshCaptureTests`の隔離compositionを使う。`FUMINIWA_VISUAL_CAPTURE=1`でView描画、macOSの`FUMINIWA_EXTERNAL_CAPTURE=1`で外部撮影の受渡しを有効にする。実作品・実アカウント・実サーバーを使用しない。
