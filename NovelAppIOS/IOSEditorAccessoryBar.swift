import EditorKit
import Observation
import SwiftUI

@MainActor
@Observable
final class IOSEditorAccessoryCommandState {
    var pendingOperation: IOSEditorAccessoryPendingOperation?
    var rubySheet: IOSEditorRubySheetState?
    var replacementError: String?
    private(set) var lastReplacementID: UUID?

    var isBusy: Bool {
        pendingOperation != nil || rubySheet != nil
    }

    func request(
        _ operation: IOSEditorAccessoryOperation,
        commandSession: EditorCommandSession
    ) {
        guard !isBusy, commandSession.pendingCommand == nil else { return }

        replacementError = nil
        let id = commandSession.requestSelectionSnapshot()
        guard commandSession.rejectedCommandID != id else {
            replacementError = Self.rejectedMessage
            return
        }
        pendingOperation = IOSEditorAccessoryPendingOperation(id: id, operation: operation)
    }

    func receiveSelectionSnapshot(
        _ snapshot: EditorSelectionSnapshot?,
        commandSession: EditorCommandSession
    ) {
        guard
            let pendingOperation,
            let snapshot,
            snapshot.id == pendingOperation.id else { return }

        self.pendingOperation = nil
        switch pendingOperation.operation {
        case .ellipsis:
            replaceSelection(with: "……", snapshotID: snapshot.id, commandSession: commandSession)
        case .dash:
            replaceSelection(with: "――", snapshotID: snapshot.id, commandSession: commandSession)
        case .ruby:
            rubySheet = IOSEditorRubySheetState(snapshot: snapshot)
        case .bouten:
            guard let notation = EditorNotationRules.bouten(text: snapshot.text) else {
                replacementError = "傍点を付ける文字を選択してください。"
                return
            }
            replaceSelection(with: notation, snapshotID: snapshot.id, commandSession: commandSession)
        }
    }

    func completeRuby(
        parentText: String,
        rubyText: String,
        commandSession: EditorCommandSession
    ) {
        guard
            let rubySheet,
            let notation = EditorNotationRules.ruby(parentText: parentText, rubyText: rubyText) else { return }

        self.rubySheet = nil
        replaceSelection(
            with: notation,
            snapshotID: rubySheet.snapshot.id,
            commandSession: commandSession
        )
    }

    func cancelRuby() {
        rubySheet = nil
    }

    func receiveRejectedCommandID(_ rejectedID: UUID?) {
        guard let rejectedID else { return }
        guard
            rejectedID == pendingOperation?.id ||
            rejectedID == rubySheet?.snapshot.id ||
            rejectedID == lastReplacementID else { return }

        pendingOperation = nil
        rubySheet = nil
        lastReplacementID = nil
        replacementError = Self.rejectedMessage
    }

    private func replaceSelection(
        with text: String,
        snapshotID: UUID,
        commandSession: EditorCommandSession
    ) {
        lastReplacementID = snapshotID
        commandSession.replaceSelection(id: snapshotID, text: text)
        if commandSession.rejectedCommandID == snapshotID {
            receiveRejectedCommandID(snapshotID)
        }
    }

    private static let rejectedMessage =
        "変換中、または本文や選択範囲が変わったため挿入できませんでした。選択し直して再度実行してください。"
}

enum IOSEditorAccessoryOperation: Equatable {
    case ellipsis
    case dash
    case ruby
    case bouten

    var keyboardShortcut: KeyEquivalent {
        switch self {
        case .ellipsis:
            "1"
        case .dash:
            "2"
        case .ruby:
            "3"
        case .bouten:
            "4"
        }
    }
}

struct IOSEditorAccessoryPendingOperation: Equatable {
    let id: UUID
    let operation: IOSEditorAccessoryOperation
}

struct IOSEditorRubySheetState: Identifiable, Equatable {
    let snapshot: EditorSelectionSnapshot

    var id: UUID {
        snapshot.id
    }
}

@MainActor
struct IOSEditorAccessoryBar: View {
    let commandSession: EditorCommandSession
    @State private var commandState: IOSEditorAccessoryCommandState

    init(
        commandSession: EditorCommandSession,
        commandState: IOSEditorAccessoryCommandState = IOSEditorAccessoryCommandState()
    ) {
        self.commandSession = commandSession
        _commandState = State(initialValue: commandState)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                accessoryButton(
                    title: "……",
                    hint: "三点リーダーを挿入します。",
                    identifier: "ios.editor.accessory.ellipsis",
                    operation: .ellipsis
                )

                accessoryButton(
                    title: "――",
                    hint: "ダッシュを挿入します。",
                    identifier: "ios.editor.accessory.dash",
                    operation: .dash
                )

                accessoryButton(
                    title: "ルビ",
                    hint: "選択範囲を親文字にして、なろう形式のルビを追加します。",
                    identifier: "ios.editor.accessory.ruby",
                    operation: .ruby
                )

                accessoryButton(
                    title: "傍点",
                    hint: "選択範囲になろう形式の傍点を追加します。",
                    identifier: "ios.editor.accessory.bouten",
                    operation: .bouten
                )
                .disabled(!commandSession.hasNonEmptySelection)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .background(IOSPalette.editorCanvas)
        .overlay(alignment: .top) {
            Divider()
        }
        .environment(\.colorScheme, .dark)
        .disabled(
            !commandSession.hasActiveEditorSurface ||
                commandSession.isDocumentTransitionPrepared ||
                commandSession.pendingCommand != nil ||
                commandState.isBusy ||
                commandState.rubySheet != nil
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("執筆補助")
        .onChange(of: commandSession.selectionSnapshot) { _, snapshot in
            commandState.receiveSelectionSnapshot(snapshot, commandSession: commandSession)
        }
        .onChange(of: commandSession.rejectedCommandID) { _, rejectedID in
            commandState.receiveRejectedCommandID(rejectedID)
        }
        .sheet(item: rubySheetBinding) { state in
            IOSEditorRubySheet(
                state: state,
                onCancel: commandState.cancelRuby
            ) { parentText, rubyText in
                commandState.completeRuby(
                    parentText: parentText,
                    rubyText: rubyText,
                    commandSession: commandSession
                )
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .alert("挿入できませんでした", isPresented: replacementErrorIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(commandState.replacementError ?? "")
        }
    }

    private func accessoryButton(
        title: String,
        hint: String,
        identifier: String,
        operation: IOSEditorAccessoryOperation
    ) -> some View {
        Button(title) {
            commandState.request(operation, commandSession: commandSession)
        }
        .keyboardShortcut(operation.keyboardShortcut, modifiers: [.command, .option])
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
        .accessibilityIdentifier(identifier)
    }

    private var replacementErrorIsPresented: Binding<Bool> {
        Binding(
            get: { commandState.replacementError != nil },
            set: { isPresented in
                if !isPresented {
                    commandState.replacementError = nil
                }
            }
        )
    }

    private var rubySheetBinding: Binding<IOSEditorRubySheetState?> {
        Binding(
            get: { commandState.rubySheet },
            set: { commandState.rubySheet = $0 }
        )
    }
}

@MainActor
private struct IOSEditorRubySheet: View {
    let state: IOSEditorRubySheetState
    let onCancel: () -> Void
    let onComplete: (String, String) -> Void

    @FocusState private var focusedField: Field?
    @State private var parentText: String
    @State private var rubyText = ""

    init(
        state: IOSEditorRubySheetState,
        onCancel: @escaping () -> Void,
        onComplete: @escaping (String, String) -> Void
    ) {
        self.state = state
        self.onCancel = onCancel
        self.onComplete = onComplete
        _parentText = State(initialValue: state.snapshot.text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("ルビ") {
                    TextField("親文字", text: $parentText)
                        .focused($focusedField, equals: .parent)
                        .accessibilityIdentifier("ios.editor.ruby.parent")
                    TextField("ルビ", text: $rubyText)
                        .focused($focusedField, equals: .ruby)
                        .accessibilityIdentifier("ios.editor.ruby.reading")
                }

                Section("プレビュー") {
                    Text(previewText)
                        .foregroundStyle(notation == nil ? .secondary : .primary)
                        .accessibilityIdentifier("ios.editor.ruby.preview")
                }
            }
            .navigationTitle("ルビを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", role: .cancel) {
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加") {
                        guard notation != nil else { return }
                        onComplete(parentText, rubyText)
                    }
                    .disabled(notation == nil)
                    .accessibilityIdentifier("ios.editor.ruby.add")
                }
            }
        }
        .onAppear {
            focusedField = state.snapshot.text.isEmpty ? .parent : .ruby
        }
    }

    private var notation: String? {
        EditorNotationRules.ruby(parentText: parentText, rubyText: rubyText)
    }

    private var previewText: String {
        notation ?? "親文字とルビを入力するとプレビューが表示されます。"
    }

    private enum Field {
        case parent
        case ruby
    }
}
