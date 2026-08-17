import EditorKit
import Foundation
import NovelAuth
import NovelAuthApple
import NovelCore
import NovelStorage
import NovelSyncV2Application
import NovelSyncV2PortableBridge

/// アプリが使う依存関係の組み立てを担当する(docs/DESIGN.md 5.1)。
///
/// `AppState` や `ContentView` が `NovelpkgRepository` のような具象型を
/// 直接知らなくて済むように、依存の生成をここに閉じ込める。現行の通常版AIは
/// clipboard writerだけを注入し、provider／network／sidecarは組み立てない(D-075)。
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

    /// 自動作成する原稿のapp-private保存root名。
    let defaultDocumentDirectoryName: String

    /// 表示中の本文エディタを、作品遷移前にIME確定・モデル同期・入力停止する境界。
    let editorCommandSession: EditorCommandSession

    /// Explicit clipboard boundary for the local prompt-copy feature.
    let clipboardWriter: any PlainTextClipboardWriting

    /// 表示中Editorの確定済み全文を、本文所有権を破らず読み取る境界。
    let activeCommittedTextCapture: @MainActor () -> EditorCommittedTextCaptureResult

    /// Sign in with Apple is an optional account layer. Local editing remains
    /// available when the auth server is unreachable or not configured.
    let authSessionCoordinator: AuthSessionCoordinator?
    let appleSignInCoordinator: AppleSignInCoordinator?
    let appleAuthenticationOrchestrator: AppleAuthenticationOrchestrator?
    /// v2 runtime is created by the macOS composition root.  The app state
    /// never constructs a URL session, SQLite handle, or v1 worker itself.
    let snapshotSyncV2Factory: (@Sendable () async throws -> SyncV2Application)?
    let snapshotSyncV2DocumentGate: MacSyncV2DocumentGate?
    let portableBridge: SyncV2PortableBridge

    init(
        repository: DocumentRepository = NovelpkgRepository(),
        attachmentManager: AttachmentManaging? = nil,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        defaultDocumentDirectoryName: String = AppBuildFlavor.defaultDocumentDirectoryName,
        editorCommandSession: EditorCommandSession = EditorCommandSession(),
        clipboardWriter: any PlainTextClipboardWriting = SystemPlainTextClipboardWriter(),
        activeCommittedTextCapture: (@MainActor () -> EditorCommittedTextCaptureResult)? = nil,
        authSessionCoordinator: AuthSessionCoordinator? = nil,
        appleSignInCoordinator: AppleSignInCoordinator? = nil,
        appleAuthenticationOrchestrator: AppleAuthenticationOrchestrator? = nil,
        snapshotSyncV2Factory: (@Sendable () async throws -> SyncV2Application)? = nil,
        snapshotSyncV2DocumentGate: MacSyncV2DocumentGate? = nil,
        portableBridge: SyncV2PortableBridge? = nil
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
        self.authSessionCoordinator = authSessionCoordinator
        self.appleSignInCoordinator = appleSignInCoordinator
        self.appleAuthenticationOrchestrator = appleAuthenticationOrchestrator
        self.snapshotSyncV2Factory = snapshotSyncV2Factory
        self.snapshotSyncV2DocumentGate = snapshotSyncV2DocumentGate
        if let portableBridge {
            self.portableBridge = portableBridge
        } else if let repository = repository as? any PortableDocumentPackageRepository & AttachmentManaging {
            self.portableBridge = SyncV2PortableBridge(repository: repository)
        } else {
            self.portableBridge = SyncV2PortableBridge()
        }
    }
}
