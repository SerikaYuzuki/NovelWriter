import Foundation
import NovelCore
import NovelStorage

/// アプリが使う依存関係の組み立てを担当する(docs/DESIGN.md 5.1)。
///
/// `AppState` や `ContentView` が `NovelpkgRepository` のような具象型を
/// 直接知らなくて済むように、依存の生成をここに閉じ込める。将来 AI クライアントや
/// 設定ストア・Exporter を追加する際もここに足していく。
@MainActor
struct AppDependencies {
    /// 作品の読み込み・保存を担当するリポジトリ。App 側は `DocumentRepository`
    /// プロトコルのみを見て、`.novelpkg` の内部構造を知らない(docs/DESIGN.md 9.3)。
    let repository: DocumentRepository

    /// 「最近開いた作品」のファイルパスを保存する場所(D-009)。
    let userDefaults: UserDefaults

    /// 既定の保存先ディレクトリの探索に使う。
    let fileManager: FileManager

    init(
        repository: DocumentRepository = NovelpkgRepository(),
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.repository = repository
        self.userDefaults = userDefaults
        self.fileManager = fileManager
    }
}
