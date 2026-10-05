import NovelCore

public enum AssistantFeedbackContext: String, CaseIterable, Identifiable {
    case work, characters, position
    public var id: String {
        rawValue
    }

    public var label: String {
        switch self {
        case .work: "作品名・あらすじ"
        case .characters: "登場人物（名前・役割の要約）"
        case .position: "話の位置（第何章第何話）"
        }
    }

    public static func reference(document: NovelDocument, episodeIDs: Set<EpisodeID>, selected: Set<Self>) -> String? {
        var blocks: [String] = []
        if selected.contains(.work) {
            blocks.append("作品名: \(document.title)\nあらすじ: \(document.synopsis)")
        }
        if selected.contains(.characters) {
            blocks.append("登場人物（名前・役割の要約）:\n" + (document.characters.isEmpty ? "（登録なし）" : document.characters.map {
                "- \($0.name): \(($0.role?.isEmpty == false ? $0.role : nil) ?? "役割未登録")"
            }.joined(separator: "\n")))
        }
        if selected.contains(.position) {
            let positions = document.chapters.enumerated().flatMap { chapterIndex, chapter in
                chapter.episodes.enumerated().compactMap { episodeIndex, episode -> String? in
                    guard episodeIDs.contains(episode.id) else { return nil }
                    return "- 第\(chapterIndex + 1)章「\(chapter.title)」 第\(episodeIndex + 1)話「\(episode.title)」"
                }
            }
            blocks.append("話の位置（章内の話順）:\n" + positions.joined(separator: "\n"))
        }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }
}
