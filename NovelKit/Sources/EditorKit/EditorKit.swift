import NovelCore

/// EditorKit
///
/// 本文エディタを提供するモジュール。macOS では `NSTextView`、iOS では将来
/// `UITextView` をアダプタ経由で利用する(docs/DESIGN.md 4.3)。
///
/// 依存: NovelCore のみ(docs/DESIGN.md 9.1)。
/// 実装ルール(docs/DESIGN.md 9.2): AppKit / UIKit は `Platform/` 配下に閉じ込め、
/// Public API に `NSTextView` / `UITextView` を出してはならない。
///
/// ディレクトリ構成:
/// - `EditorView.swift` Phase 1 で実装した Public な SwiftUI Facade
/// - `Core/`     EditorPlugin / EditorContext / EditorPluginPipeline(Phase 2 で実装済み)
/// - `Rules/`    自動インデント(`IndentRules`)などの純粋な判定ロジック。テキスト
///   所有権ルールの判定(`TextOwnershipPolicy`)は Phase 1 で導入済み
/// - `Plugins/`  IndentPlugin / IMEGuardPlugin などの具象プラグイン(Phase 2 で実装済み)
/// - `Platform/macOS/` AppKit 依存の実装(`MacTextAdapter`。`#if canImport(AppKit)` で保護)
public enum EditorKit {}
