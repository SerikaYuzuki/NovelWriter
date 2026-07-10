import NovelCore
import SwiftUI

enum ProjectSection: String, CaseIterable, Codable, Identifiable {
    case projectInfo
    case planning
    case structure
    case plot
    case characters
    case worldbuilding
    case references
    case settings

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .projectInfo:
            "作品情報"
        case .planning:
            "企画"
        case .structure:
            "執筆"
        case .plot:
            "プロット"
        case .characters:
            "登場人物"
        case .worldbuilding:
            "世界観"
        case .references:
            "資料"
        case .settings:
            "設定"
        }
    }

    var systemImage: String {
        switch self {
        case .projectInfo:
            "book.closed"
        case .planning:
            "lightbulb"
        case .structure:
            "list.bullet.indent"
        case .plot:
            "rectangle.stack"
        case .characters:
            "person.2"
        case .worldbuilding:
            "globe.asia.australia"
        case .references:
            "paperclip"
        case .settings:
            "gearshape"
        }
    }

    var keyboardShortcut: KeyEquivalent {
        switch self {
        case .projectInfo:
            "1"
        case .planning:
            "2"
        case .structure:
            "3"
        case .plot:
            "4"
        case .characters:
            "5"
        case .worldbuilding:
            "6"
        case .references:
            "7"
        case .settings:
            "8"
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

enum AIAssistantTab: String, CaseIterable, Identifiable {
    case chat
    case suggestions
    case selectionActions

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .chat:
            "チャット"
        case .suggestions:
            "提案"
        case .selectionActions:
            "選択範囲"
        }
    }
}

struct AIAssistantPanelState: Equatable {
    var isExpanded = false
    var height: CGFloat = 280
    var inputText = ""
    var selectedTab: AIAssistantTab = .chat
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
