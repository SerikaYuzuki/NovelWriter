import Foundation
import NovelCore
import NovelTiming

/// Shared macOS / iOS revision gate.  A normal save owns only the in-memory document
/// value; WorkID/SQLite is selected by the Snapshot Sync runtime.  URL-based
/// package writes remain explicit import/export operations outside this type.
@MainActor
public final class V2DocumentSaveCoordinator {
    public enum SaveEvent: Sendable, Equatable {
        case dirty, saving, saved, failed
    }

    public enum ExclusiveOperationResult<Value: Sendable>: Sendable {
        case saveFailedBeforeOperation
        case completed(value: Value, savedAfterOperation: Bool)
    }

    private let timing: FuminiwaTiming
    public typealias DebounceSleep = @MainActor @Sendable (UInt64) async throws -> Void

    private let debounceSleep: DebounceSleep
    private let currentDocument: @MainActor () -> NovelDocument?
    private let saveOperation: @MainActor @Sendable (NovelDocument) async throws -> Void
    private let saveEventHandler: @MainActor @Sendable (SaveEvent) -> Void
    private var saveRevision = 0
    private var savedRevision = 0
    private var isSaving = false
    private var immediateSaveRequested = false
    private var isExclusiveRunning = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var exclusiveWaiters: [CheckedContinuation<Void, Never>] = []
    private var debouncedSaveTask: Task<Void, Never>?

    public init(
        timing: FuminiwaTiming = .init(),
        debounceSleep: @escaping DebounceSleep = { try await Task.sleep(nanoseconds: $0) },
        currentDocument: @escaping @MainActor () -> NovelDocument?,
        saveOperation: @escaping @MainActor @Sendable (NovelDocument) async throws -> Void,
        saveEventHandler: @escaping @MainActor @Sendable (SaveEvent) -> Void = { _ in }
    ) {
        self.timing = timing
        self.debounceSleep = debounceSleep
        self.currentDocument = currentDocument
        self.saveOperation = saveOperation
        self.saveEventHandler = saveEventHandler
    }

    public var lastSavedRevision: Int {
        savedRevision
    }

    public func markDirty() {
        saveRevision += 1
        saveEventHandler(.dirty)
    }

    public func scheduleDebouncedSave() {
        scheduleDebouncedSave(after: timing.autosaveDebounceSeconds)
    }

    private func scheduleDebouncedSave(after seconds: Double) {
        debouncedSaveTask?.cancel()
        debouncedSaveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await debounceSleep(UInt64(seconds * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            // The timer no longer owns the checkpoint: later typing cancels
            // only the next timer, never the in-flight durable save.
            debouncedSaveTask = nil
            guard !isSaving, !isExclusiveRunning else {
                scheduleDebouncedSave(after: timing.autosavePostSaveWaitSeconds)
                return
            }
            _ = await saveDirtyRevisions(flushAll: false)
        }
    }

    @discardableResult
    public func saveNow() async -> Bool {
        debouncedSaveTask?.cancel()
        debouncedSaveTask = nil
        while isExclusiveRunning {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                exclusiveWaiters.append(continuation)
            }
        }
        if isSaving {
            immediateSaveRequested = true
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                waiters.append(continuation)
            }
        }
        return await saveDirtyRevisions()
    }

    public func performExclusive<T: Sendable>(_ operation: () async throws -> T) async rethrows -> T {
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

    public func performExclusiveAfterFlushing<T: Sendable>(
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

    private func saveDirtyRevisions(flushAll: Bool = true) async -> Bool {
        guard savedRevision < saveRevision else { return true }
        isSaving = true
        immediateSaveRequested = false
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
                if !flushAll, !immediateSaveRequested {
                    break
                }
            } catch {
                succeeded = false
                break
            }
        }
        isSaving = false
        immediateSaveRequested = false
        saveEventHandler(succeeded ? (savedRevision == saveRevision ? .saved : .dirty) : .failed)
        if !flushAll, succeeded, savedRevision < saveRevision, debouncedSaveTask == nil {
            scheduleDebouncedSave(after: timing.autosavePostSaveWaitSeconds)
        }
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
