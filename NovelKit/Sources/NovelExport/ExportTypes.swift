import Foundation

/// NovelWriter が書き出せる原稿形式。
///
/// 実装が利用可能になった形式だけを公開し、未実装の形式を選択可能にはしない。
public enum ExportFormat: String, CaseIterable, Codable, Equatable, Sendable {
    case plainText
    case markdown
    case epub

    /// 保存先の既定ファイル名に使う拡張子。
    public var filenameExtension: String {
        switch self {
        case .plainText:
            "txt"
        case .markdown:
            "md"
        case .epub:
            "epub"
        }
    }
}

/// 1回の書き出しに適用する設定。
///
/// EPUB / PDF のレイアウト設定を将来追加しても、呼び出し側が保存形式ごとの
/// 具象レンダラを知る必要がないよう独立した値型にしている。
public struct ExportOptions: Equatable, Sendable {
    public var format: ExportFormat

    public init(format: ExportFormat) {
        self.format = format
    }
}

/// 原稿の生成またはアトミックな書き込みで発生する型付きエラー。
public enum ExportError: Error, Equatable, Sendable {
    /// 指定形式の生成物を構築できない。
    case renderingFailed(format: ExportFormat, reason: String)
    /// 保存先がファイルURLではない。
    case invalidDestination(URL)
    /// 保存先の親ディレクトリを準備できない。
    case destinationPreparationFailed(destination: URL, reason: String)
    /// 完成した生成物を同じ親ディレクトリの一時ファイルへ書けない。
    case temporaryWriteFailed(destination: URL, reason: String)
    /// 一時ファイルを保存先へ移動または置換できない。
    case destinationReplacementFailed(destination: URL, reason: String)
}

extension ExportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .renderingFailed(format, reason):
            "\(format.rawValue) の生成に失敗しました: \(reason)"
        case let .invalidDestination(destination):
            "書き出し先がファイルURLではありません: \(destination.absoluteString)"
        case let .destinationPreparationFailed(destination, reason):
            "書き出し先を準備できませんでした(\(destination.path)): \(reason)"
        case let .temporaryWriteFailed(destination, reason):
            "一時ファイルへ書き込めませんでした(\(destination.path)): \(reason)"
        case let .destinationReplacementFailed(destination, reason):
            "書き出し先を置き換えられませんでした(\(destination.path)): \(reason)"
        }
    }
}
