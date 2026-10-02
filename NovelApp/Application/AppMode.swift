import NovelCore
import NovelUI
import SwiftUI

enum ProjectSection: String, CaseIterable, Codable, Identifiable {
    case projectInfo
    case structure
    case plot
    case characters
    case worldbuilding
    case references
    case feedback
    case settings

    var id: String {
        rawValue
    }

    var style: ProjectSectionStyle {
        self == .structure ? .writing : ProjectSectionStyle(rawValue: rawValue)!
    }

    var title: String {
        style.title
    }

    var systemImage: String {
        style.systemImage
    }

    var keyboardShortcut: KeyEquivalent {
        switch self {
        case .projectInfo:
            "1"
        case .structure:
            "2"
        case .plot:
            "3"
        case .characters:
            "4"
        case .worldbuilding:
            "5"
        case .references:
            "6"
        case .feedback:
            "8"
        case .settings:
            "7"
        }
    }
}

struct OutlineItemID: RawRepresentable, Hashable, Codable {
    var rawValue: String
}

struct WorkspaceSelection: Equatable, Codable {
    var section: ProjectSection
    var outlineItemID: OutlineItemID?

    init(section: ProjectSection = .structure, outlineItemID: OutlineItemID? = nil) {
        self.section = section
        self.outlineItemID = outlineItemID
    }
}

struct WorkspaceFeatureDescriptor: Identifiable, Equatable {
    var section: ProjectSection
    var supportsOutlineItems: Bool
    var supportsCommands: Bool
    var supportsStatusItems: Bool

    var id: ProjectSection {
        section
    }
}

struct OutlinePresentationState: Equatable {
    var searchText = ""
    var isSearchVisible = false
    var pinnedSearchByKeyboard = false
}

/// プロット画面 content 列の選択(UIFIX 4.2)。執筆の章選択とは独立させる。
enum PlotOutlineSelection: Hashable, Sendable {
    case unassigned
    case chapter(ChapterID)
}

enum CharacterProfileField {
    case role
    case age
    case gender
    case firstPerson
    case secondPerson
    case speechStyle
    case appearance
    case personality
    case background
}
