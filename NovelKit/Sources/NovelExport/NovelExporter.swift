import Foundation
import NovelCore

/// `NovelDocument` の値から再現可能な生成物を作る書き出し境界。
///
/// `.novelpkg` やApp状態には依存せず、呼び出し時に渡された値だけを読む。
public struct NovelExporter: Equatable, Sendable {
    public init() {}

    /// 原稿をメモリ上で生成する。バイナリ形式を追加できるよう戻り値は `Data` とする。
    public func render(_ document: NovelDocument, options: ExportOptions) throws -> Data {
        let manuscript = Manuscript.expand(document)
        let rendered: String = switch options.format {
        case .plainText:
            PlainTextRenderer().render(manuscript)
        case .markdown:
            MarkdownRenderer().render(manuscript)
        }

        // SwiftのStringからUTF-8への変換は常に成功し、BOMも付与しない。
        return Data(rendered.utf8)
    }

    /// 原稿を一時ファイルへ完成させ、成功した場合だけ保存先を置き換える。
    public func export(
        _ document: NovelDocument,
        to destinationURL: URL,
        options: ExportOptions
    ) throws {
        let data = try render(document, options: options)
        try AtomicExportWriter.write(data, to: destinationURL)
    }
}
