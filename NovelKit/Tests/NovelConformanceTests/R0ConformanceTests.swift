import CryptoKit
import Foundation
import Testing

struct R0ConformanceTests {
    @Test("reviewed v1 fixtures preserve canonical bytes and digests")
    func canonicalVectorsAgree() throws {
        let files = fixtureFiles()
        try #require(!files.isEmpty, "No reviewed v1 JSON fixtures were found")

        var vectorCount = 0
        for file in files {
            let data = try Data(contentsOf: file)
            let value = try JSONSerialization.jsonObject(with: data)
            vectorCount += try verify(value, source: file, location: "$")
        }
        #expect(vectorCount > 0)
    }

    private func fixtureFiles() -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directories = [
            root.appendingPathComponent("docs/sync/v1"),
            root.appendingPathComponent("docs/auth/v1")
        ]

        return directories.flatMap { directory -> [URL] in
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return [URL]()
            }
            return enumerator.compactMap { item -> URL? in
                guard let url = item as? URL, url.pathExtension == "json" else { return nil }
                return url
            }
        }.sorted { $0.path < $1.path }
    }

    private func verify(_ value: Any, source: URL, location: String) throws -> Int {
        var count = 0
        if let object = value as? [String: Any] {
            if let canonical = object["expectedCanonicalUtf8"] as? String {
                let data = Data(canonical.utf8)
                if let expectedByteCount = object["expectedByteCount"] as? NSNumber {
                    #expect(
                        data.count == expectedByteCount.intValue,
                        "\(source.path):\(location): byte count mismatch"
                    )
                }
                let digest = SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined()
                if let expectedSha = object["expectedSha256"] as? String {
                    #expect(
                        digest == expectedSha,
                        "\(source.path):\(location): SHA-256 mismatch"
                    )
                }
                if let expectedHex = object["expectedCanonicalUtf8Hex"] as? String {
                    #expect(
                        data.map { String(format: "%02x", $0) }.joined() == expectedHex,
                        "\(source.path):\(location): UTF-8 hex mismatch"
                    )
                }
                count += 1
            }
            for (key, child) in object {
                count += try verify(child, source: source, location: "\(location).\(key)")
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                count += try verify(child, source: source, location: "\(location)[\(index)]")
            }
        }
        return count
    }
}
