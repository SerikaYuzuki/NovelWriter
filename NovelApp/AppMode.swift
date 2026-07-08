import SwiftUI

enum AppMode: String, CaseIterable, Identifiable {
    case writing
    case characters
    case plot

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .writing:
            "執筆"
        case .characters:
            "キャラクター"
        case .plot:
            "プロット"
        }
    }

    var systemImage: String {
        switch self {
        case .writing:
            "square.and.pencil"
        case .characters:
            "person.2"
        case .plot:
            "rectangle.stack"
        }
    }
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
