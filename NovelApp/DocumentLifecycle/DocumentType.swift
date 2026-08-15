import UniformTypeIdentifiers

extension UTType {
    /// `.novelpkg`のwire contractは変えず、Finder上のふみにわ作品として関連付ける。
    static let fuminiwaNovelPackage = UTType(
        exportedAs: "dev.serikayuzuki.fuminiwa.novelpackage",
        conformingTo: .package
    )
}
