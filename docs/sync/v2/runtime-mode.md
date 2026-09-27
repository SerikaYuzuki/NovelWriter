# v2 RuntimeModeと実行環境の分離

目的は、test／previewの操作から利用者のSQLite、URL、Keychainへ到達できない構成にすること。規範はD-080、現行型は`NovelKit/Sources/NovelSyncV2Application/RuntimeMode.swift`、組み立ては`NovelSyncV2Runtime/SnapshotSyncV2Runtime.swift`にある。

```swift
public enum RuntimeMode: Sendable {
    case production(ProductionRuntimeConfiguration)
    case test(TestRuntimeConfiguration)
    case preview(PreviewRuntimeConfiguration)
}
```

| mode | 構成 | 成功条件 |
| --- | --- | --- |
| production | `ProductionLocalRoot`、optional `ProductionHTTPSOrigin`／auth vault、document gate | platform Application Support配下の`FUMINIWA/SnapshotSyncV2/`だけを開き、online未設定でもlocal編集できる |
| test | `TestLocalRoot`、`TestDefaults`、`TestSyncV2Vault`、`FakeSyncV2RemoteClient` | runごとの一時root・defaults・fakeから利用者領域や本番transportへ到達できない |
| preview | 固定値 | SQLite／network／Keychain I/Oを起こさない |

modeはrootやtransportの生成前に決まる。任意のUserDefaults値で起動後に切り替えない。production構成はtest rootを受け取らず、test構成はproduction URL／Keychainを受け取らない。rootはsymlinkと領域外pathを拒否し、production originはcredential、query、fragmentを含まないHTTPS originに限定する。

現在archive専用executableは提供していない。RuntimeModeにarchive caseを追加しない。live appへv1 reader、dual-read、fallbackを接続しない。

検証は`Scripts/check-sync-v2-boundary.sh`と対応するapplication/runtime testsを使う。testが利用者のDB／WAL／SHMを生成しないことまで確認し、型定義があるだけで分離達成としない。
