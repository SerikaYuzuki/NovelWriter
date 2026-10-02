import Foundation
import NovelCore
import NovelTextAnalysis
import Observation

@MainActor
@Observable
final class CharacterAppearanceSession {
    private(set) var appearances: [CharacterAppearance] = []
    private(set) var isLoading = false
    private var revision = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?

    func refresh(character: NovelCore.Character?, document: NovelDocument) {
        task?.cancel()
        revision = UUID()
        appearances = []
        isLoading = character != nil
        guard let character else { return }
        let revision = revision
        task = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            let worker = Task.detached(priority: .userInitiated) {
                CharacterAppearanceDetector.appearances(for: character, in: document)
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.revision == revision else { return }
            appearances = result
            isLoading = false
        }
    }

    func cancel() {
        task?.cancel(); revision = UUID()
    }
}
