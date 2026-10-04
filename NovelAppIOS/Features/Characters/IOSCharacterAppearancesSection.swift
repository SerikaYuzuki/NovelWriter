import NovelCore
import NovelTextAnalysis
import NovelUI
import NovelWorkspace
import SwiftUI

struct IOSCharacterAppearancesSection: View {
    @Environment(WorkspaceModel.self) private var workspace
    let store: IOSDocumentStore
    let character: NovelCore.Character
    let openEditor: () -> Void
    @State private var appearanceSession = CharacterAppearanceSession()

    var body: some View {
        Section("登場") {
            if appearanceSession.isLoading {
                ProgressView("登場を確認中")
            } else {
                Text(CharacterAppearanceDetector.summary(appearanceSession.appearances))
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(appearanceSession.appearances) { appearance in
                    Button {
                        let scope = store.workSearchScope
                        Task {
                            guard await store.selectWorkTextMatch(
                                chapterID: appearance.chapterID,
                                episodeID: appearance.episodeID,
                                source: appearance.source,
                                range: appearance.range,
                                expectedScope: scope
                            ) else { return }
                            openEditor()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: Spacing.extraSmall) {
                            Text("\(appearance.chapterTitle) · \(appearance.episodeTitle)")
                            Text("\(appearance.count)回").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityHint("話を開き、最初の一致箇所を選択します")
                }
            }
        }
        .onAppear { appearanceSession.setVisible(true, character: character, document: workspace.document) }
        .onChange(of: workspace.editGeneration) { _, _ in refresh() }
        .onChange(of: character) { _, _ in refresh() }
        .onChange(of: store.workSearchScope) { _, _ in refresh() }
        .onDisappear { appearanceSession.setVisible(false, character: character, document: workspace.document) }
    }

    private func refresh() {
        appearanceSession.refresh(character: character, document: workspace.document)
    }
}
