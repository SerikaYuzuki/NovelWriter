import Foundation

/// `.novelpkg` パッケージの読み込み・保存で発生しうる型付きエラー。
///
/// 設計方針(docs/DESIGN.md「データが壊れにくいこと」): 話ファイルが1つ欠けている
/// 程度では読み込み全体を失敗させない(データ救出優先)。そのため `chapterFileMissing`
/// のようなケースはエラーにはせず、空本文として読み込む。ここに定義されているのは
/// 「読み込み・保存そのものを継続できない」種類の失敗のみ。
public enum NovelpkgError: Error, Sendable, Equatable {
    /// 指定した URL に `.novelpkg` パッケージ(フォルダ)が存在しない。
    case packageNotFound(URL)
    /// `manifest.json` が存在しない。
    case manifestMissing(URL)
    /// `manifest.json` の読み込み・デコードに失敗した(壊れている)。
    case manifestCorrupted(url: URL, reason: String)
    /// メタデータファイル(`characters.json` / `plot.json` / `flags.json`)の
    /// 読み込み・デコードに失敗した(壊れている)。`manifest.json` 自体は無事な
    /// ケースなので `manifestCorrupted` とは区別する(Phase 4 レビュー F-C)。
    case metadataCorrupted(url: URL, file: String, reason: String)
    /// `manifest.json` の `formatVersion` が、この実装の対応バージョンではない。
    case unsupportedFormatVersion(String)
    /// 保存処理(アトミック書き込みのための一時ディレクトリ操作など)に失敗した。
    case saveFailed(reason: String)
}

extension NovelpkgError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .packageNotFound(url):
            "パッケージが見つかりません: \(url.path)"
        case let .manifestMissing(url):
            "manifest.json が見つかりません: \(url.path)"
        case let .manifestCorrupted(url, reason):
            "manifest.json の読み込みに失敗しました(\(url.path)): \(reason)"
        case let .metadataCorrupted(url, file, reason):
            "\(file) の読み込みに失敗しました(\(url.path)): \(reason)"
        case let .unsupportedFormatVersion(version):
            "対応していないフォーマットバージョンです: \(version)"
        case let .saveFailed(reason):
            "保存に失敗しました: \(reason)"
        }
    }
}
