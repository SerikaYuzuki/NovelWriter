import NovelCore

// `MacTextAdapter`(docs/DESIGN.md 4.3)は Phase 2 で実装する。
// AppKit に触れるコードは、iOS 向けコンパイル(→ D-013)を壊さないよう
// 必ず `#if canImport(AppKit)` で保護すること(docs/DESIGN.md 9.2)。
// このファイルは iOS ビルドでは中身が空になる。
#if canImport(AppKit)
import AppKit

/// 将来 `NSTextView` を保持する macOS 実装を置く場所。
/// Public API に `NSTextView` を出してはならない(docs/DESIGN.md 9.2)。
enum MacTextAdapterPlaceholder {}
#endif
