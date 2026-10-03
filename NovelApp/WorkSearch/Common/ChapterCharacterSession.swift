import Foundation
import NovelCore
import NovelTextAnalysis
import Observation

/// 既存の章context menuも本文検出をメインスレッドで行わない。
@MainActor
@Observable
final class ChapterCharacterSession {
    private(set) var characterIDs: Set<CharacterID> = []
    private(set) var isLoading = false
    private var revision = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?

    func refresh(chapter: Chapter?, characters: [NovelCore.Character]) {
        task?.cancel(); revision = UUID(); characterIDs = []
        guard let chapter else { isLoading = false; return }
        isLoading = true
        let revision = revision
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                Set(characters.filter { character in
                    chapter.episodes.contains { episode in
                        !CharacterAppearanceDetector.appearances(for: character, in: episode,
                                                                 chapterID: chapter.id, chapterTitle: chapter.title)
                            .isEmpty
                    }
                }.map(\.id))
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.revision == revision else { return }
            characterIDs = result; isLoading = false
        }
    }

    func cancel() {
        task?.cancel(); revision = UUID()
    }
}
