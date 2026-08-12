import EditorKit
import Foundation
import NovelCore
import NovelStorage

/// アプリが使う依存関係の組み立てを担当する(docs/DESIGN.md 5.1)。
///
/// `AppState` や `ContentView` が `NovelpkgRepository` のような具象型を
/// 直接知らなくて済むように、依存の生成をここに閉じ込める。AI providerは通常版へ
/// 混入させず、Experimental専用compositionで組み立てる(D-046)。
@MainActor
struct AppDependencies {
    /// 作品の読み込み・保存を担当するリポジトリ。App 側は `DocumentRepository`
    /// プロトコルのみを見て、`.novelpkg` の内部構造を知らない(docs/DESIGN.md 9.3)。
    let repository: DocumentRepository

    /// 資料添付の操作を担当する抽象。非対応リポジトリでは `nil`。
    let attachmentManager: AttachmentManaging?

    /// 「最近開いた作品」のファイルパスを保存する場所(D-009)。
    let userDefaults: UserDefaults

    /// 既定の保存先ディレクトリの探索に使う。
    let fileManager: FileManager

    /// 自動作成する原稿を通常版とExperimental版で同じ場所へ書かないためのroot名。
    let defaultDocumentDirectoryName: String

    /// 表示中の本文エディタを、作品遷移前にIME確定・モデル同期・入力停止する境界。
    let editorCommandSession: EditorCommandSession

    /// 利用者が明示したprompt copyだけをsystem clipboardへ書く境界。
    let clipboardWriter: any PlainTextClipboardWriting

    /// 表示中Editorの確定済み全文を、本文所有権を破らず読み取る境界。
    let activeCommittedTextCapture: @MainActor () -> EditorCommittedTextCaptureResult

    /// Device Syncが設定済みの場合だけ注入するtransport-neutral runtime。
    let deviceSyncRuntime: DeviceSyncRuntime?

    init(
        repository: DocumentRepository = NovelpkgRepository(),
        attachmentManager: AttachmentManaging? = nil,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        defaultDocumentDirectoryName: String = AppBuildFlavor.defaultDocumentDirectoryName,
        editorCommandSession: EditorCommandSession = EditorCommandSession(),
        clipboardWriter: any PlainTextClipboardWriting = SystemPlainTextClipboardWriter(),
        activeCommittedTextCapture: (@MainActor () -> EditorCommittedTextCaptureResult)? = nil,
        deviceSyncRuntime: DeviceSyncRuntime? = nil
    ) {
        self.repository = repository
        self.attachmentManager = attachmentManager ?? repository as? AttachmentManaging
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        self.defaultDocumentDirectoryName = defaultDocumentDirectoryName
        self.editorCommandSession = editorCommandSession
        self.clipboardWriter = clipboardWriter
        self.activeCommittedTextCapture = activeCommittedTextCapture ?? {
            editorCommandSession.captureActiveCommittedText()
        }
        self.deviceSyncRuntime = deviceSyncRuntime
    }
}
