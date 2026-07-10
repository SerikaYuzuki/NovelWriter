import Foundation
import NovelCore
@testable import NovelStorage
import Testing

/// Phase 4.5-3b: 代表パッケージでの保存性能予算と計測。
///
/// 既定の `swift test` / `Scripts/check.sh` では重い I/O を走らせない。
/// 実測は `NOVELWRITER_PERF_TEST=1 ./Scripts/measure-save-performance.sh` で行う。
enum SavePerformanceBudget {
    /// 本文サイズ(UTF-8 バイト)。
    static let bodyByteCount = 1_000_000
    /// 添付ファイルサイズ。
    static let attachmentByteCount = 100 * 1024 * 1024
    /// スナップショット個数。
    static let snapshotCount = 20

    /// 代表パッケージの上書き保存に許容する wall time。
    /// APFS の clonefile により実コピーが省略される環境でも、章書き出し・
    /// ディレクトリ操作・replace の合計がこの範囲に収まることを期待する。
    static let overwriteSaveDuration: Duration = .seconds(15)
}

private struct PreparedRepresentativePackage {
    let body: String
    let attachmentSize: Int
    let setupElapsed: Duration
}

private enum SavePerformanceFixture {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["NOVELWRITER_PERF_TEST"] == "1"
    }

    static func makeBodyContent(byteCount: Int) -> String {
        let unit = "あいうえおかきくけこ"
        let unitBytes = unit.utf8.count
        let repeats = max(1, byteCount / unitBytes)
        var content = String(repeating: unit, count: repeats)
        while content.utf8.count < byteCount {
            content.append("あ")
        }
        return content
    }

    static func writeAttachmentFile(at url: URL, byteCount: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        let chunkSize = 1024 * 1024
        let chunk = Data(repeating: 0x61, count: chunkSize)
        var remaining = byteCount
        while remaining > 0 {
            let size = min(chunkSize, remaining)
            try handle.write(contentsOf: chunk.prefix(size))
            remaining -= size
        }
    }

    static func seconds(from duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    static func prepareRepresentativePackage(
        repository: NovelpkgRepository,
        packageURL: URL,
        attachmentSourceURL: URL
    ) async throws -> PreparedRepresentativePackage {
        let body = makeBodyContent(byteCount: SavePerformanceBudget.bodyByteCount)
        var document = NovelDocument(
            title: "保存性能測定",
            chapters: [Chapter(title: "第1章", content: body)]
        )
        try await repository.save(document, to: packageURL)

        try writeAttachmentFile(
            at: attachmentSourceURL,
            byteCount: SavePerformanceBudget.attachmentByteCount
        )
        let attachmentSize = try #require(
            try FileManager.default.attributesOfItem(atPath: attachmentSourceURL.path)[.size] as? Int
        )
        _ = try await repository.addAttachment(from: attachmentSourceURL, to: packageURL)

        let setupClock = ContinuousClock()
        let setupStartedAt = setupClock.now
        for index in 1 ... SavePerformanceBudget.snapshotCount {
            document.chapters[0].content = body + "\n// snapshot \(index)"
            _ = try await repository.saveSnapshot(document, to: packageURL)
        }
        return PreparedRepresentativePackage(
            body: body,
            attachmentSize: attachmentSize,
            setupElapsed: setupStartedAt.duration(to: setupClock.now)
        )
    }
}

@Test(
    "代表パッケージ(1MB本文・100MB添付・20スナップショット)の上書き保存が予算内",
    .enabled(
        if: SavePerformanceFixture.isEnabled,
        "NOVELWRITER_PERF_TEST=1 のときだけ実行(Scripts/measure-save-performance.sh)"
    )
)
func overwriteSaveOfRepresentativePackageStaysWithinBudget() async throws {
    let tempDir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let packageURL = tempDir.appendingPathComponent("PerfFixture.novelpkg")
    let attachmentSourceURL = tempDir.appendingPathComponent("large-reference.bin")
    let repository = NovelpkgRepository()
    let prepared = try await SavePerformanceFixture.prepareRepresentativePackage(
        repository: repository,
        packageURL: packageURL,
        attachmentSourceURL: attachmentSourceURL
    )

    #expect(prepared.body.utf8.count >= SavePerformanceBudget.bodyByteCount)
    #expect(prepared.attachmentSize == SavePerformanceBudget.attachmentByteCount)
    #expect(try await repository.listSnapshots(in: packageURL).count == SavePerformanceBudget.snapshotCount)

    var document = try await repository.load(from: packageURL)
    document.chapters[0].content = prepared.body + "\n// measured overwrite"

    let clock = ContinuousClock()
    let startedAt = clock.now
    try await repository.save(document, to: packageURL)
    let elapsed = startedAt.duration(to: clock.now)

    print(
        "NovelWriter perf: setup(snapshots)="
            + "\(String(format: "%.3f", SavePerformanceFixture.seconds(from: prepared.setupElapsed)))s "
            + "overwrite save elapsed="
            + "\(String(format: "%.3f", SavePerformanceFixture.seconds(from: elapsed)))s "
            + "budget=\(SavePerformanceBudget.overwriteSaveDuration) "
            + "body=\(SavePerformanceBudget.bodyByteCount)B "
            + "attachment=\(prepared.attachmentSize)B "
            + "snapshots=\(SavePerformanceBudget.snapshotCount)"
    )

    #expect(elapsed <= SavePerformanceBudget.overwriteSaveDuration)
    #expect(try await repository.load(from: packageURL).chapters[0].content.hasSuffix("// measured overwrite"))
    #expect(try await repository.listSnapshots(in: packageURL).count == SavePerformanceBudget.snapshotCount)
    #expect(try await repository.listAttachments(in: packageURL).count == 1)
}
