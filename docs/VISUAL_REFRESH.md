# 残りの画面計画

色・文字・寸法・placeholder・動きは[STYLE](STYLE.md)を正とする。外観既定・本文・IME・執筆補助バーは維持する。

1. 棚：端末ごとのgrid/list切替、表紙＋明朝作品名＋状態。macOS左にbrand画像、操作は「新規」＋「…」。iOSは独立したアカウントsection、＋menuに新規／取り込み。挨拶・今日の文字数・最近開いた順は追加しない。
2. iOS作品ホーム：表紙hero＋あらすじ3行、共有の文字数／400字詰め枚数／章／話。機能を2列tileと件数、AX文字サイズではlist。同期1行、競合時のみ既存3択、履歴・書き出しは「その他」。
3. 人物：avatar行、詳細hero（72pt、名前・ふりがな・役割）、sectionをcard化。色選択はring＋checkmark＋日本語色名。登場検出をcacheしてから追加する。
4. 世界観：行28ptサムネイル、画像があるときだけ詳細hero。本文編集領域は維持する。
5. プロット／伏線：surface card、10pt角丸、hairline、選択1.5pt accent ring。macOS hoverはわずかに明るく、影はdrag中だけ。空は点線drop領域。iPad grid／iPhone icon＋2行memo。未回収flag＋warning、回収済みcheckmark.circle.fill＋leaf。

macOS最小幅700／Outline最小224、iPad Split View、iPhone AX Dynamic Typeを確認する。サムネイルは表示寸法decode・cache、gridはLazyVGrid。保存経路へUI処理を入れない。

- iOS work home: remove internal jargon such as 「スナップショット履歴」 (use 「履歴」) and 「作品パッケージ」 wording per STYLE §1/§6 when redesigning.
