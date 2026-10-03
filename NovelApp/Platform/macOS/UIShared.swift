import AppKit
import EditorKit
import Foundation
import NovelCore
import NovelUI
import SwiftUI

struct OperationMessage: Identifiable {
    let id = UUID()
    let title: String
    let body: String
}

/// Workbenchのdetail chromeやOutline pane全体で共通利用するtranslucent surface。
struct WorkbenchGlassChromeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            // `.thinMaterial` は Reduce Transparency をOS標準の不透明表現へ
            // 自動でフォールバックするため、個別の外観分岐を持たない。
            .background(.thinMaterial)
    }
}

/// Outline系Listの選択・スクロール背景だけを整えるmodifier。materialは含めない。
struct WorkbenchOutlineListModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
    }
}

extension View {
    func workbenchGlassChromeStyle() -> some View {
        modifier(WorkbenchGlassChromeModifier())
    }

    func workbenchOutlineListStyle() -> some View {
        modifier(WorkbenchOutlineListModifier())
    }

    /// 単体のOutline List向け。Listスタイルとglass surfaceを1層で適用する。
    func workbenchGlassOutlineStyle() -> some View {
        workbenchOutlineListStyle()
            .workbenchGlassChromeStyle()
    }
}

/// 1行入力のラベルとコントロールを縦に積む共通部品。
struct WorkbenchLabeledField<Content: View>: View {
    let label: String
    private let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 長文入力のラベル、内側余白、境界線を統一する共通部品。
struct WorkbenchLabeledEditor<Content: View>: View {
    let label: String
    private let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
                // TextEditorの標準bezelは、この共通部品が所有するhairlineと
                // 二重に見える。入力面はplainにして、境界は外側の1本だけにする。
                .textEditorStyle(.plain)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 1)
                }
        }
    }
}

struct CharacterColorSwatch: View {
    let colorHex: String?
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                Circle()
                    .stroke(.secondary.opacity(0.35), lineWidth: 1)
            }
    }

    private var color: Color {
        guard let colorHex, let color = Color(hex: colorHex) else {
            return .clear
        }
        return color
    }
}

struct CharacterRow: View {
    let character: NovelCore.Character
    var thumbnailData: Data?

    var body: some View {
        HStack(spacing: 8) {
            ThumbnailImage(data: thumbnailData, kind: .character, title: character.name, size: 24, color: character.colorHex.flatMap { Color(hex: $0) }).accessibilityHidden(true)
            CharacterColorSwatch(colorHex: character.colorHex)
                .layoutPriority(1)

            VStack(alignment: .leading, spacing: 2) {
                Text(NovelDocument.normalizedCharacterName(character.name))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !character.kana.isEmpty {
                    Text(character.kana)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PlotCardRow: View {
    let card: PlotCard
    let chapterTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(NovelDocument.normalizedPlotCardTitle(card.title))
                .lineLimit(1)
            if let chapterTitle {
                Text(chapterTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct FlagRow: View {
    let flag: Flag
    let plantedTitle: String?
    var selected = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: flag.isResolved ? "checkmark.circle.fill" : "flag")
                .foregroundStyle(flag.isResolved ? FuminiwaColor.leaf.color : FuminiwaColor.warning.color)

            VStack(alignment: .leading, spacing: 2) {
                Text(NovelDocument.normalizedFlagTitle(flag.title))
                    .lineLimit(1)
                if let plantedTitle {
                    Text(plantedTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(selected: selected)
    }
}

struct AttachmentRow: View {
    let attachment: Attachment

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.fileName)
                    .lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

struct ManuscriptStatusBar: View {
    let chapterCharacterCount: Int
    let totalCharacterCount: Int

    var body: some View {
        HStack(spacing: 16) {
            Text("章 \(chapterCharacterCount)字 / \(ManuscriptMetrics.manuscriptPages400(for: chapterCharacterCount))枚")
            Spacer()
            Text("全体 \(totalCharacterCount)字 / \(ManuscriptMetrics.manuscriptPages400(for: totalCharacterCount))枚")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }
}

extension NSColor {
    var hexString: String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        let red = Int(round(rgb.redComponent * 255))
        let green = Int(round(rgb.greenComponent * 255))
        let blue = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
