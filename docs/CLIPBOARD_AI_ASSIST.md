# 原稿のコピー

D-094: 明示した範囲の原稿をplain textでコピーする。

選択範囲・話・章をコピーする。AIへの依頼文、JSON、BEGIN/ENDの囲み、用途選択を付けない。[明示送信のAI支援](WRITING_ASSISTANT.md)は独立した機能として維持する。

## コピーする内容

| 範囲 | 内容 |
| --- | --- |
| 選択範囲 | 選択した文字列そのまま |
| この話 | 話タイトル、空行、本文。空タイトルなら本文だけ |
| この章 | 章タイトル、空行、各話のタイトルと本文を配列順に空行で区切る |

Unicode、空白、改行、原稿中の引用符を変換しない。章の空話を落とさず、空タイトルへ仮見出しを補わない。本文がすべて空白／改行ならタイトルだけをコピーせず拒否する。

話メモ、人物、プロット、伏線、世界観、資料、作品metadata、ID、session、surface、revision、URL／path、保存状態、認証情報を追加しない。

対象のtitle／content／text合計は250,000文字かつUTF-8 1,000,000 bytes以下、区切り追加後の出力はUTF-8 2,000,000 bytes以下。超過時はwrite前に全体拒否し、切り詰めない。これは端末内のresource上限である。

## 実装と操作

- 共有builder: [`ManuscriptCopy.swift`](../NovelApp/ManuscriptCopy.swift)。Mac / iOS両targetから利用する。
- macOS: 章／話行のコピーボタン・右クリック、本文選択の右クリック。
- iOS: 執筆画面の「コピー」メニューに「この話をコピー」「この章をコピー」、選択context menuに「選択範囲をコピー」。
- 成功は「コピーしました」。AI送信・DB保存・外部アプリ起動は行わない。

明示操作1回につきclipboard writeは最大1回。item準備を置換前に終え、準備失敗なら既存clipboardを保持する。置換開始後のwrite失敗では元clipboardの保持を保証せず、成功表示、自動retry、復元を行わない。コピー結果の通知には原稿を保持しない。自動消去もしない。

## Session・IME・所有権

menu表示時のsessionと対象IDを保持し、activation時に再検査する。作品切替後に別作品へ読み替えない。選択はEditorKit公開command境界を通し、native viewを探索しない。IME中は拒否し、確定後の新しい明示操作を待つ。

章／話は操作時点の確定したmemory値を使う。現在話はEditorKitの確定本文を優先し、選択外のeditor内容を混ぜない。コピー自体は原稿の編集、Undo、自動保存を変更する操作ではない。

## 検証

共有builderで選択のexact Unicode、タイトル・章配列順・空話、上限、AI依頼文なしの出力を確認する。Mac AppStateとiOSのclipboard差替えテストでwrite回数、IME、失効session、対象削除、空本文、write失敗を確認する。実端末への反映はbuild / install / 起動と区別して記録する。
