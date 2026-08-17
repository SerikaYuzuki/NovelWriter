import Foundation
import NovelCore

/// URLを持たないmacOS v2用の保存直列化境界。
///
/// 通常保存のidentityはWorkID/SQLiteであり、パッケージURLをCoordinatorへ
/// 渡さない。明示的なImport/ExportだけがRepositoryを直接呼び出す。
@MainActor
final class V2DocumentSaveCoordinator {
    enum SaveEvent: Sendable, Equatable {
        case dirty
        case saving
        case saved
        case failed
    }

    private let debounceNanoseconds: UInt64
    private let currentDocument: @MainActor () -> NovelDocument?
    private let saveOperation: @MainActor @Sendable (NovelDocument) async throws -> Void
    private let saveEventHandler: @MainActor @Sendable (SaveEvent) -> Void
    private var revision = 0
    private var savedRevision = 0
    private var isSaving = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var debouncedSaveTask: Task<Void, Never>?

    init(
        debounceNanoseconds: UInt64,
        currentDocument: @escaping @MainActor () -> NovelDocument?,
        saveOperation: @escaping @MainActor @Sendable (NovelDocument) async throws -> Void,
        saveEventHandler: @escaping @MainActor @Sendable (SaveEvent) -> Void = { _ in }
    ) {
        self.debounceNanoseconds = debounceNanoseconds
        self.currentDocument = currentDocument
        self.saveOperation = saveOperation
        self.saveEventHandler = saveEventHandler
    }

    func markDirty() {
        revision &+= 1
        saveEventHandler(.dirty)
    }

    func scheduleDebouncedSave() {
        debouncedSaveTask?.cancel()
        debouncedSaveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            _ = await saveNow()
        }
    }

    @discardableResult
    func saveNow() async -> Bool {
        debouncedSaveTask?.cancel()
        debouncedSaveTask = nil
        if isSaving {
            return await withCheckedContinuation { waiters.append($0) }
        }
        isSaving = true
        var succeeded = true
        while savedRevision != revision {
            guard let document = currentDocument() else {
                succeeded = false
                break
            }
            saveEventHandler(.saving)
            do {
                try await saveOperation(document)
                savedRevision = revision
                saveEventHandler(.saved)
            } catch {
                succeeded = false
                saveEventHandler(.failed)
                break
            }
        }
        isSaving = false
        let result = succeeded && savedRevision == revision
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume(returning: result) }
        return result
    }
}
