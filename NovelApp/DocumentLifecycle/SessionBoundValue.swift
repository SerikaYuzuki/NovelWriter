/// UIに表示した値と、その値が属していた作品セッションを一体で保持する。
///
/// 非同期の作品切り替え後も残り得るcontext menuや確認ダイアログが、
/// 古い値を現在作品へ適用しないために使う。
struct SessionBoundValue<Value> {
    let value: Value
    let session: DocumentSessionToken
}

/// TextKit側の本文所有権を「本文install世代 + 本文ID」で識別する。
///
/// 別名保存したpackageや複製packageは話・世界観ノートのIDを共有し得るため、
/// 本文IDだけをEditorViewへ渡すと作品切替時のinitialText再読込を判定できない。
/// 一方、本文が変わらない別名保存では世代を進めずcaret/Undoを保持する。
struct SessionBoundEditorKey<Value: Hashable>: Hashable {
    let value: Value
    let generation: UInt64
}

extension SessionBoundValue: Identifiable where Value: Identifiable {
    var id: Value.ID {
        value.id
    }
}
