import AppKit
import SwiftUI

struct AIProofreadingPresentationRow: View {
    let label: String
    let value: String
    let isMonospaced: Bool
    let isNumeric: Bool

    init(
        _ label: String,
        value: String,
        isMonospaced: Bool = false,
        isNumeric: Bool = false
    ) {
        self.label = label
        self.value = value
        self.isMonospaced = isMonospaced
        self.isNumeric = isNumeric
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            if isMonospaced {
                Text(verbatim: value)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            } else if isNumeric {
                Text(verbatim: value)
                    .monospacedDigit()
                    .textSelection(.enabled)
            } else {
                Text(verbatim: value)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct AIProofreadingExactTextSection: View {
    let title: String
    let text: String
    let isMonospaced: Bool

    var body: some View {
        GroupBox(title) {
            AIProofreadingExactTextBlock(
                text: text,
                label: title,
                isMonospaced: isMonospaced
            )
        }
    }
}

struct AIProofreadingExactTextBlock: View {
    let text: String
    let label: String
    let isMonospaced: Bool
    var allowsTextSelection = true

    var body: some View {
        selectableText
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(8)
            .background(
                Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator, lineWidth: 1)
            }
            .accessibilityLabel(label)
            .accessibilityValue(text)
    }

    @ViewBuilder
    private var selectableText: some View {
        if allowsTextSelection {
            textContent.textSelection(.enabled)
        } else {
            textContent.textSelection(.disabled)
        }
    }

    @ViewBuilder
    private var textContent: some View {
        if isMonospaced {
            Text(verbatim: text)
                .font(.body.monospaced())
        } else {
            Text(verbatim: text)
                .font(.body)
        }
    }
}

struct AIProofreadingMissingStateView: View {
    var body: some View {
        ContentUnavailableView(
            "表示できる状態がありません",
            systemImage: "exclamationmark.triangle",
            description: Text("パネルを閉じ、本文を選択してからやり直してください。")
        )
    }
}
