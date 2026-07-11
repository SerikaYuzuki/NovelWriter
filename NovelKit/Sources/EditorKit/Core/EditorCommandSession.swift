import Foundation
import Observation

/// 本文エディタへ明示的な操作を配送するcommand。
///
/// AppKitのテキストビューを公開せず、選択範囲の取得と置換を同じIDで対応付ける。
public enum EditorCommand: Sendable, Equatable {
    case requestSelectionSnapshot(UUID)
    case replaceSelection(id: UUID, text: String)

    var id: UUID {
        switch self {
        case let .requestSelectionSnapshot(id), let .replaceSelection(id: id, text: _):
            id
        }
    }
}

/// `EditorCommand`で取得した選択範囲のスナップショット。
public struct EditorSelectionSnapshot: Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let range: NSRange

    public init(id: UUID, text: String, range: NSRange) {
        self.id = id
        self.text = text
        self.range = range
    }
}

/// SwiftUIとプラットフォームAdapterの間でEditor commandを配送する一時状態。
///
/// 本文・選択の正はAdapter内のテキストビューに置き、ここにはcommandと結果だけを持つ。
@MainActor
@Observable
public final class EditorCommandSession {
    public private(set) var pendingCommand: EditorCommand?
    public private(set) var selectionSnapshot: EditorSelectionSnapshot?
    public private(set) var rejectedCommandID: UUID?

    public init() {}

    @discardableResult
    public func requestSelectionSnapshot() -> UUID {
        let id = UUID()
        pendingCommand = .requestSelectionSnapshot(id)
        rejectedCommandID = nil
        return id
    }

    public func replaceSelection(id: UUID, text: String) {
        pendingCommand = .replaceSelection(id: id, text: text)
        rejectedCommandID = nil
    }

    func receiveSelectionSnapshot(_ snapshot: EditorSelectionSnapshot) {
        guard pendingCommand?.id == snapshot.id else { return }
        selectionSnapshot = snapshot
        pendingCommand = nil
    }

    func completeCommand(id: UUID) {
        guard pendingCommand?.id == id else { return }
        pendingCommand = nil
    }

    func rejectCommand(id: UUID) {
        guard pendingCommand?.id == id else { return }
        rejectedCommandID = id
        pendingCommand = nil
    }
}
