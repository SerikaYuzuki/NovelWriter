# Auth v2: Mac 配布版のブラウザ認証契約

## 状態と範囲

これは実装前の契約である。既存の Auth v1 native Apple 認証、iOS / iPadOS、発行済み session、Snapshot Sync v2 の wire と AccountID は変更しない。Mac の Developer ID 配布版で Apple Web と Google OpenID Connect を使うための新しい認証入口を設ける。Auth epoch と endpoint の変更は、実装・fixture・OpenAPI をそろえてから有効にする。

## 開始から session 取得まで

1. Mac アプリが provider (`apple` または `google`) と、端末内で生成した 256-bit の引換秘密のハッシュを HTTPS でサーバーに送る。サーバーは短命の attempt、推測不能な `state` と `nonce`、認可 URL を作り、attempt ID と URL だけをアプリに返す。
2. アプリが URL をシステムの既定ブラウザで開く。認可 URL の `redirect_uri` は provider に登録した固定 HTTPS callback と完全一致させる。Apple は `https://sync.serika.work/v2/auth/browser/apple/callback` を登録した Services ID、Google は `https://sync.serika.work/v2/auth/browser/google/callback` を登録した Web application OAuth client を使用する。
3. callback は `state`、有効期限、単回使用を先に検査する。サーバーが provider の code を token endpoint で引き換え、ID token の署名、issuer、audience、期限、nonce、subject を検証する。provider の code、ID token、FUMINIWA token をブラウザからアプリへ URL で渡さない。callback の HTML には認証情報を埋め込まない。
4. アプリだけが attempt ID と引換秘密で完了を問い合わせる。成功時にサーバーが短命の引換を一度だけ消費し、FUMINIWA session を TLS のレスポンス本文でアプリへ返す。未完了、取消、期限切れ、別 attempt の秘密、再使用、サーバー再起動を区別して扱う。引換秘密、provider credential、FUMINIWA token はログや通常保存 DB に残さない。
5. アプリは既存の Keychain と account transition gate を通して session を導入する。別 AccountID のローカル作品は自動採用しない。認証待ちの間も SQLite 保存と編集を続けられる。

## アカウントの対応

- Apple Web の verified subject は、同じ primary App ID に属する既存 native Apple identity と照合し、同一人物の AccountID を保つ。実アカウントで subject が一致しない場合はログインを停止し、作品を移動・統合しない。
- Google の identity key は Google issuer と verified subject に基づき、Apple identity とは別の AccountID にする。email、表示名、端末からの申告値を identity key にしない。
- 1 AccountID に active な provider kind は一つだけとし、DB 制約と同一 transaction 内の確認で守る。provider の連携・変更・account merge は提供しない。Google でサインインした端末から Apple で入り直す操作は、通常の account 切替として扱う。
- Google の要求 scope は認証に必要な最小限にし、Google の長期 access / refresh token を FUMINIWA の同期 token として保存しない。Apple の credential と失効通知は既存の保全規則を維持する。

## 外部設定と受入

- Apple Developer の Services ID は `dev.serikayuzuki.fuminiwa.web`。所有者は primary Mac App ID への関連付け、`sync.serika.work`、上記 return URL の保存完了を報告した。保存後の read-back、既存 Apple subject との一致と実認証は未確認。Google Cloud project ID は所有者申告で `eco-shift-452410-t2`、14:08 作成の OAuth client ID は `560354700432-aq87npqhidi1m4n671m8pb9bugml609d.apps.googleusercontent.com`。Google callback は設定画面で入力済みと所有者が報告したが、保存後の read-back と実認証は未確認。秘密鍵と client secret はサーバーの secret 管理に置き、repo と DMG に含めない。
- callback は provider ごとに固定し、認可 URL・token request と登録値の完全一致を確認する。`state` / `nonce` 不一致、期限切れ、code 再使用、cross-attempt、provider 取り違え、重複 callback、サーバー再起動を合成データと実 DB で確認する。
- 既存 Apple native client の認証・更新・削除操作が回帰しないことを確認する。Apple Web で既存 AccountID に戻ること、Google で独立 AccountID になること、同期 scope と端末ローカル作品の保全を実アカウントで確認する。
