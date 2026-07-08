import Foundation
@testable import NovelCore
import Testing

/// `DocumentSaveCoordinator` に対するテスト(docs/DESIGN.md 6.4, D-017)。
///
/// 主眼は、check-then-act 競合の回帰防止: 「保存中に markDirty() → 保存完了直後に
/// saveNow()」という interleaving でも、新しい revision が確実に保存され、
/// どの呼び出しも「true を返したのに未保存の revision が残る」ことがないことを
/// 検証する。
@MainActor
struct DocumentSaveCoordinatorTests {
    /// 保存処理をテストから任意のタイミングで一時停止・再開できるフェイク。
    ///
    /// `pauseNextCall()` を呼んでおくと、次の `perform` 呼び出しは `release()` される
    /// まで内部で `await` し続ける。これにより「保存の実行中」を確定的に再現する。
    @MainActor
    private final class PausableSaveSpy {
        private(set) var savedTitles: [String] = []
        private var errorToThrowOnce: (any Error)?
        private var shouldPauseNextCall = false
        private var gate: CheckedContinuation<Void, Never>?

        var isPaused: Bool {
            gate != nil
        }

        func pauseNextCall() {
            shouldPauseNextCall = true
        }

        func throwOnNextCall(_ error: any Error) {
            errorToThrowOnce = error
        }

        func release() {
            gate?.resume()
            gate = nil
        }

        func perform(_ document: NovelDocument, _: URL) async throws {
            if shouldPauseNextCall {
                shouldPauseNextCall = false
                await withCheckedContinuation { continuation in
                    gate = continuation
                }
            }

            if let error = errorToThrowOnce {
                errorToThrowOnce = nil
                throw error
            }

            savedTitles.append(document.title)
        }
    }

    /// テストから自由に書き換えられる、保存対象の可変な状態。
    @MainActor
    private final class MutableDocumentState {
        var document: NovelDocument
        let url = URL(fileURLWithPath: "/tmp/DocumentSaveCoordinatorTests.novelpkg")

        init(title: String) {
            document = NovelDocument(title: title, chapters: [Chapter(title: "第1章")])
        }
    }

    private struct SpyError: Error, Equatable {}

    private func makeCoordinator(
        state: MutableDocumentState,
        spy: PausableSaveSpy,
        debounceNanoseconds: UInt64 = 1
    ) -> DocumentSaveCoordinator {
        DocumentSaveCoordinator(
            debounceNanoseconds: debounceNanoseconds,
            currentState: { [weak state] in
                guard let state else { return nil }
                return (state.document, state.url)
            },
            saveOperation: { [weak spy] document, url in
                guard let spy else { return }
                try await spy.perform(document, url)
            }
        )
    }

    @Test func saveNowWithoutDirtyStateReturnsTrueWithoutSaving() async {
        let state = MutableDocumentState(title: "初期状態")
        let spy = PausableSaveSpy()
        let coordinator = makeCoordinator(state: state, spy: spy)

        let result = await coordinator.saveNow()

        #expect(result == true)
        #expect(spy.savedTitles.isEmpty)
    }

    @Test func markDirtyThenSaveNowPersistsCurrentState() async {
        let state = MutableDocumentState(title: "保存対象")
        let spy = PausableSaveSpy()
        let coordinator = makeCoordinator(state: state, spy: spy)

        coordinator.markDirty()
        let result = await coordinator.saveNow()

        #expect(result == true)
        #expect(spy.savedTitles == ["保存対象"])
    }

    @Test func saveNowReturnsFalseWhenSaveOperationThrows() async {
        let state = MutableDocumentState(title: "失敗テスト")
        let spy = PausableSaveSpy()
        spy.throwOnNextCall(SpyError())
        let coordinator = makeCoordinator(state: state, spy: spy)

        coordinator.markDirty()
        let result = await coordinator.saveNow()

        #expect(result == false)
    }

    /// F1 の回帰テスト本体。
    ///
    /// 1. A が `saveNow()` を呼び、保存処理の途中(スパイのゲート内)で止まる。
    /// 2. A が保存中のあいだに本文を書き換えて `markDirty()` する
    ///    (「実行中の保存の裏で新しい編集が入った」状況の再現)。
    /// 3. その状態のまま B が `saveNow()` を呼ぶ。A が保存ループを回している
    ///    (owner)ため、B は waiter として join するはず。
    /// 4. A の保存処理を再開させる。
    ///
    /// 修正前の実装(Task を await → 呼び出し元が `activeSaveTask = nil`)だと、
    /// 「A のタスクが完了した直後・nil化前」に B が join すると、A の完了済みタスクの
    /// 結果をそのまま受け取ってしまい、新しい dirty (2番目の本文)を保存しないまま
    /// `true` を返しうる。修正後の実装は owner が dirty で無くなるまでループを回す
    /// ため、B も含めて「両方の revision が保存済み」であることを保証する。
    @Test func concurrentSaveNowDuringInFlightSaveObservesLaterDirtyRevision() async {
        let state = MutableDocumentState(title: "v1")
        let spy = PausableSaveSpy()
        let coordinator = makeCoordinator(state: state, spy: spy)

        coordinator.markDirty()
        spy.pauseNextCall()

        let taskA = Task { await coordinator.saveNow() }

        // A が保存処理の内部(ゲート)で止まるまで待つ。
        while !spy.isPaused {
            await Task.yield()
        }

        // A が保存中のあいだに、新しい編集が入って dirty になる。
        state.document.title = "v2"
        coordinator.markDirty()

        // 保存完了直後を狙って B が saveNow() を呼ぶ(A が owner のため join するはず)。
        let taskB = Task { await coordinator.saveNow() }
        await Task.yield()

        // A の1回目の保存を再開させる。
        spy.release()

        let resultA = await taskA.value
        let resultB = await taskB.value

        #expect(resultA == true)
        #expect(resultB == true)
        // v1, v2 の両方が保存されている(新しい revision が保存されずに
        // 握りつぶされていない)。
        #expect(spy.savedTitles == ["v1", "v2"])

        // 保存し残しが無いことの最終確認: 追加の markDirty() なしで saveNow() しても
        // 保存処理は再度呼ばれない。
        let resultAfter = await coordinator.saveNow()
        #expect(resultAfter == true)
        #expect(spy.savedTitles == ["v1", "v2"])
    }

    @Test func scheduleDebouncedSaveEventuallySavesAfterDelay() async throws {
        let state = MutableDocumentState(title: "デバウンス")
        let spy = PausableSaveSpy()
        let coordinator = makeCoordinator(state: state, spy: spy, debounceNanoseconds: 10_000_000)

        coordinator.markDirty()
        coordinator.scheduleDebouncedSave()

        #expect(spy.savedTitles.isEmpty)

        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(spy.savedTitles == ["デバウンス"])
    }
}
