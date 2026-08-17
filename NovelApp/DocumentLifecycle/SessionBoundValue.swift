/// UIに表示した値と、その値が属していた作品セッションを一体で保持する。
///
/// 作品切替後も残り得るcontext menuや確認ダイアログが古い値を現在作品へ
/// 適用しないよう、値とv2のWorkIDセッションを同じ境界で検査する。
struct SessionBoundValue<Value> {
    let value: Value
    let session: DocumentSessionToken
}

struct SessionBoundEditorKey<Value: Hashable>: Hashable {
    let value: Value
    let generation: UInt64
}

extension SessionBoundValue: Identifiable where Value: Identifiable {
    var id: Value.ID {
        value.id
    }
}
