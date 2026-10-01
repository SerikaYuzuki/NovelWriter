import SwiftUI

public enum ProjectSectionStyle: String, CaseIterable, Sendable {
    case projectInfo, writing, plot, characters, worldbuilding, references, feedback, settings

    public var title: String {
        switch self {
        case .projectInfo: "作品情報"
        case .writing: "執筆"
        case .plot: "プロット"
        case .characters: "登場人物"
        case .worldbuilding: "世界観"
        case .references: "資料"
        case .feedback: "感想・アドバイス"
        case .settings: "設定"
        }
    }

    public var systemImage: String {
        switch self {
        case .projectInfo: "book.closed"
        case .writing: "square.and.pencil"
        case .plot: "rectangle.stack"
        case .characters: "person.2"
        case .worldbuilding: "globe.asia.australia"
        case .references: "paperclip"
        case .feedback: "text.bubble"
        case .settings: "gearshape"
        }
    }

    public var label: some View {
        Label(title, systemImage: systemImage).symbolRenderingMode(.hierarchical)
    }
}
