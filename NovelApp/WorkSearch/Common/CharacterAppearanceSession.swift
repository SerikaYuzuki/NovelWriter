import Foundation
import NovelCore
import NovelTextAnalysis
import Observation

@MainActor
@Observable
final class CharacterAppearanceSession {
    private(set) var appearances: [CharacterAppearance] = []
    private(set) var isLoading = false
    private(set) var isStale = true
    @ObservationIgnored private var isVisible = true
    @ObservationIgnored private let detect: @Sendable (NovelCore.Character, NovelDocument) -> [CharacterAppearance]
    @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?

    init(detect: @escaping @Sendable (NovelCore.Character, NovelDocument) -> [CharacterAppearance] = {
        CharacterAppearanceDetector.appearances(for: $0, in: $1)
    }, sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.detect = detect
        self.sleep = sleep
    }

    func setVisible(_ visible: Bool, character: NovelCore.Character?, document: NovelDocument) {
        isVisible = visible
        if visible {
            if isStale {
                refresh(character: character, document: document)
            }
        } else {
            cancel()
        }
    }

    func refresh(character: NovelCore.Character?, document: NovelDocument) {
        guard isVisible else { cancel(); return }
        task?.cancel()
        revision = UUID()
        isStale = true
        isLoading = character != nil
        guard let character else { appearances = []; isStale = false; return }
        let revision = revision, detect = detect
        task = Task { [weak self] in
            guard let sleep = self?.sleep else { return }
            do { try await sleep(.milliseconds(250)) } catch { return }
            let worker = Task.detached(priority: .userInitiated) {
                detect(character, document)
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.revision == revision else { return }
            task = nil
            appearances = result
            isLoading = false
            isStale = false
        }
    }

    func cancel() {
        guard !isStale || isLoading || task != nil else { return }
        task?.cancel(); task = nil; revision = UUID()
        if !isStale {
            isStale = true
        }
        if isLoading {
            isLoading = false
        }
    }
}
