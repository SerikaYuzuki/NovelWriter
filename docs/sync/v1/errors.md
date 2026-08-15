# Snapshot Sync v1 error recovery

error code、field、HTTP responseの正は[`openapi.yaml`](openapi.yaml)である。この文書はclientの状態遷移を固定し、自由文やHTTP statusだけからretryを推測しないための写像である。すべてのerrorでもlocal SQLite保存、local履歴、編集を継続し、Intent／SealedAttempt／Conflictを捨てない。

## `retryability`の意味

| 値 | client動作 |
| --- | --- |
| `afterBackoff` | `Retry-After`／`retryAfterSeconds`後に、同じbindingと同じsealed command bytesをretryする |
| `afterAuthentication` | credentialを更新した後、account fenceを変えず同じrequestをretryする。別accountなら送らずquarantineする |
| `afterBootstrap` | local current／Intent／Conflictを保ったままcapabilitiesとfull bootstrapを取り直す。新しいfence／cursorでread stateを再構築し、古い一時URIやcursorを再利用しない |
| `afterClientUpgrade` | local編集だけ継続して送信laneをparkする。対応clientへ更新後にprotocol bootstrapから再開する |
| `afterUserAction` | そのcommandはterminal／receiptedである。同じoperationを変更してretryせず、利用者操作後に新しいoperation IDとcommandをsealする |
| `never` | exact requestを自動retryしない。typed `recoveryAction`があれば指定readまたは新規sealed commandへ遷移し、なければ修復／診断待ちにする |

transport切断や応答消失はerror bodyが無いので、mutating requestでは同じoperation ID、kind、exact canonical bytesを再送してreceiptをread-backする。operation IDを別kindまたは別bytesへ再利用した`operationIdReused`はfail-closedであり、自動的に新IDへ読み替えない。local command journalの破損または実装bugとして送信laneを止める。

## 代表的なtyped recovery

- `authenticationRequired`／`tokenExpired`: credential更新。別principalへ切り替わった場合は同じwork／commandを送らない。
- `accountFenceMismatch`／`protocolEpochMismatch`／`serverInstanceMismatch`: capabilities＋bootstrapからscopeを再確認する。旧scopeのobject presence、cursor、Intent／Attemptを新scopeへ流用しない。
- `cursorExpired`／`bootstrapExpired`／`bootstrapPageTokenOutOfSequence`: full bootstrapをやり直す。local currentと未送信状態は保持する。
- `clientVersionUnsupported`: online laneをparkし、minimum client versionを表示する。open／edit／local saveは止めない。
- `rateLimited`／`temporarilyUnavailable`: server指定delayとbounded jitter後に同じreadまたはsame sealed commandをretryする。
- `quotaExceeded`: local保存は成功のまま「オンライン送信待ち」を示す。利用者は不要なonline checkpointを明示unpinし、非current／非保護版へ`releaseSnapshotPayload`を実行してlocal copyを残したまま容量を解放できる。hard rootは`snapshotPayloadProtected`で変更0とし、容量解放／契約変更後に元の送信を新しいoperationで再計画する。
- `snapshotPayloadProtected`: current head、effective pin、pending command／checkpoint、Divergence／Conflict／migration等の保護理由をread-backして表示し、同じrelease commandをblind retryしない。manual／restoreBefore reasonだけを永久保護理由にしない。対象を明示unpinするか保護処理の完了後、新operation IDをsealする。
- `uploadExpired`: serverのupload stateがexpiredで、旧quota reservationがexactly once解放済みであることをquota／upload read-backで確認する。旧upload IDとcreate／finalize commandをterminalとしてretireし、現在binding scopeでobject presenceを再確認する。不在なら **別operation ID** の`createObjectUpload`をsealする。同じexpired uploadを復活させず、旧create receipt replayでreservationを再取得しない。
- `uploadAlreadyFinalized`: object presenceをread-backし、hash／byte countとscopeが一致したときだけtransferを完了する。
- `objectAvailabilityChanged`: register対象objectがGC lifecycleで`deleting`へ進んだため、同じregister PUTをblind retryしない。`recoveryAction=replanObjectTransfer`に従いcurrent binding scopeのmissingを再照会し、不足objectのupload create／finalizeだけを新operation IDでsealしてread-backした後、同じSnapshot ID／同じcanonical manifest bytesのcontent-addressed register PUTを再実行する。register自体にoperation ID／receiptがあると仮定せず、old deletion tokenや別scopeのpresenceを再利用しない。
- `conflictAlreadyResolved`／`divergenceAlreadyClassified`: server stateをread-backし、local rowとreceiptを照合する。古い選択を再実行しない。
- `newWorkAlreadyExists`: atomic keep-bothが両headを変更していないことをread-backしてから、同じpending stateに未使用WorkIDを再予約し、新しいoperationをsealする。
- `snapshotUnavailable`: availableな版を再選択する。選択元が消えたままrestore成功に読み替えない。
- schema、hash、size、lineage、portable projection、dependency closure等のsemantic error: retryせず、原文candidateとdiagnosticを保持して修復対象にする。
- `accessDenied`／resource not found／invalid request／limit exceeded: existenceやwinnerを推測せずfail-closed。client bug、scope、fixture、利用者入力のどれかとして分類して診断する。

CAS mismatchで返るDivergence、`needsChoice` Conflict、`stale` resolve／restoreはtransport errorではなく保存済みdomain outcomeである。candidateを残してreconcileまたは再提示し、generic error toastへ畳み込まない。

## UIへ出す状態

通常UIは「この端末に保存済み」「オンラインにも保存済み」「送信待ち」「内容の確認が必要」「ログインが必要」を基本とする。backoff、cursor、operation ID、CAS、receiptは診断情報へ留める。quota、client upgrade、修復不能schema／integrity errorだけは利用者が行動できる説明を出すが、network復旧を作品openや画面遷移の前提にしない。
