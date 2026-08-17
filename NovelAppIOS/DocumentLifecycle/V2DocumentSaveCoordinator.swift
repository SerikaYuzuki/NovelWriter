import Foundation
import NovelCore

/// iOS v2 revision gate.  A normal save owns only the in-memory document
/// value; WorkID/SQLite is selected by the Snapshot Sync runtime.  URL-based
/// package writes remain explicit import/export operations outside this type.
@MainActor
final class V2DocumentSaveCoordinator {
    enum SaveEvent: Sendable, Equatable {
        case dirty, saving, saved, failed
    }

    enum ExclusiveOperationResult<Value: Sendable>: Sendable {
        case saveFailedBeforeOperation
        case completed(value: Value, savedAfterOperation: Bool)
    }

    private let debounceNanoseconds: UInt64
    private let currentDocument: @MainActor () -> NovelDocument?
    private let saveOperation: @MainActor @Sendable (NovelDocument) async throws -> Void
    private let saveEventHandler: @MainActor @Sendable (SaveEvent) -> Void
    private var saveRevision = 0
    private var savedRevision = 0
    private var isSaving = false
    private var isExclusiveRunning = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var exclusiveWaiters: [CheckedContinuation<Void, Never>] = []
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

    var lastSavedRevision: Int {
        savedRevision
    }

    func markDirty() {
        saveRevision += 1
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
        while isExclusiveRunning {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                exclusiveWaiters.append(continuation)
            }
        }
        if isSaving {
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                waiters.append(continuation)
            }
        }
        return await saveDirtyRevisions()
    }

    func performExclusive<T: Sendable>(_ operation: () async throws -> T) async rethrows -> T {
        await acquireExclusiveRegion()
        do {
            let value = try await operation()
            releaseExclusiveRegion()
            return value
        } catch {
            releaseExclusiveRegion()
            throw error
        }
    }

    func performExclusiveAfterFlushing<T: Sendable>(
        flushAfter: Bool = false,
        _ operation: () async throws -> T
    ) async rethrows -> ExclusiveOperationResult<T> {
        debouncedSaveTask?.cancel()
        debouncedSaveTask = nil
        await acquireExclusiveRegion()
        guard await saveDirtyRevisions() else {
            releaseExclusiveRegion()
            return .saveFailedBeforeOperation
        }
        do {
            let value = try await operation()
            let savedAfter = flushAfter ? await saveDirtyRevisions() : true
            releaseExclusiveRegion()
            return .completed(value: value, savedAfterOperation: savedAfter)
        } catch {
            releaseExclusiveRegion()
            throw error
        }
    }

    private func saveDirtyRevisions() async -> Bool {
        guard savedRevision < saveRevision else { return true }
        isSaving = true
        var succeeded = true
        while savedRevision < saveRevision {
            let revision = saveRevision
            guard let document = currentDocument() else {
                succeeded = false
                break
            }
            saveEventHandler(.saving)
            do {
                try await saveOperation(document)
                savedRevision = max(savedRevision, revision)
            } catch {
                succeeded = false
                break
            }
        }
        isSaving = false
        saveEventHandler(succeeded ? .saved : .failed)
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: succeeded && savedRevision == saveRevision) }
        return succeeded && savedRevision == saveRevision
    }

    private func acquireExclusiveRegion() async {
        while isSaving || isExclusiveRunning {
            if isSaving {
                _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    waiters.append(continuation)
                }
            } else {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    exclusiveWaiters.append(continuation)
                }
            }
        }
        isExclusiveRunning = true
    }

    private func releaseExclusiveRegion() {
        isExclusiveRunning = false
        let pending = exclusiveWaiters
        exclusiveWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
