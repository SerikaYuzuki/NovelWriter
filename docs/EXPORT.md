# 配布用原稿の書き出し

`NovelExport`は`NovelCore`だけに依存する。呼出時の`NovelDocument`値を固定して出力し、編集中の変更を混ぜない。生成は一時URLで行い、成功時だけ目的地を置き換える。公開APIへAppKit型やpackageのパスを出さない。

| 形式 | 内容 |
| --- | --- |
| TXT | UTF-8、BOMなし、LF。`【作品名】`、`■ 章名`、`● 話名`と本文 |
| Markdown | UTF-8、`# 作品名`、`## 章名`、`### 話名`。本文はMarkdown互換テキストを保持 |
| EPUB 3 | リフロー型、`ja`、目次、章単位XHTML。章h1・話h2、本文をHTML escapeして段落化 |

対象は作品名・章名・話名・本文。メモ、人物、プロット、伏線、資料、添付、履歴は含めない。PDF、縦書き、ルビ、画像埋込、高度な組版は未実装。

全形式で`Manuscript.expand`を使い、章→話の配列順で走査する。空章・空話も見出しを残す。空タイトルの表示名は作品「無題の作品」、章「無題の章」、話「本文」。モデル値は変更しない。

CRLF／CRはLFに統一し、本文先頭の空白と内部空行を保つ。TXT／Markdownはブロック間に空行1つ、ファイル末尾にLF1つを置く。EPUBの見た目はEditorSettingsから独立する。

実装と検証は`NovelKit/Sources/NovelExport/`、`NovelKit/Tests/NovelExportTests/`。通常保存・作品の転送形式は[保存・同期](SNAPSHOT_SYNC_V2.md)と[互換契約](CROSS_PLATFORM.md)を参照。
