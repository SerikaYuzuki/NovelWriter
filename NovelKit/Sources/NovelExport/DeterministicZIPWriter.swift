import Foundation

/// EPUB OCF用の最小ZIP writer。外部コマンドやNovelStorageに依存しない。
///
/// 全entryをstored(method 0)で書き、時刻・順序・extra fieldを固定することで、
/// 同じ原稿から常に同一Dataを生成する。ZIP64はv1の対象外とする。
enum DeterministicZIPWriter {
    struct Entry: Equatable, Sendable {
        let path: String
        let data: Data
    }

    private struct CentralRecord {
        let name: Data
        let nameLength: UInt16
        let crc32: UInt32
        let size: UInt32
        let localHeaderOffset: UInt32
    }

    private static let utf8Flag: UInt16 = 0x0800
    private static let storedMethod: UInt16 = 0
    private static let version20: UInt16 = 20
    private static let fixedDOSTime: UInt16 = 0
    private static let fixedDOSDate: UInt16 = 0x0021 // 1980-01-01

    static func archive(entries: [Entry]) throws -> Data {
        guard let entryCount = UInt16(exactly: entries.count) else {
            throw failure("ZIP entry数が上限を超えています")
        }

        var archive = Data()
        var centralRecords: [CentralRecord] = []
        centralRecords.reserveCapacity(entries.count)

        for entry in entries {
            let record = try makeCentralRecord(for: entry, archiveOffset: archive.count)
            appendLocalHeader(
                to: &archive,
                nameLength: record.nameLength,
                crc32: record.crc32,
                size: record.size
            )
            archive.append(record.name)
            archive.append(entry.data)
            centralRecords.append(record)
        }

        guard let centralDirectoryOffset = UInt32(exactly: archive.count) else {
            throw failure("ZIP64が必要なサイズです")
        }
        for record in centralRecords {
            appendCentralHeader(to: &archive, record: record)
        }
        guard let archiveSize = UInt32(exactly: archive.count) else {
            throw failure("ZIP64が必要なサイズです")
        }
        let centralDirectorySize = archiveSize - centralDirectoryOffset
        appendEndOfCentralDirectory(
            to: &archive,
            entryCount: entryCount,
            centralDirectorySize: centralDirectorySize,
            centralDirectoryOffset: centralDirectoryOffset
        )
        return archive
    }

    private static func makeCentralRecord(for entry: Entry, archiveOffset: Int) throws -> CentralRecord {
        let name = Data(entry.path.utf8)
        guard !name.isEmpty, let nameLength = UInt16(exactly: name.count) else {
            throw failure("ZIP entry名が空、または長すぎます: \(entry.path)")
        }
        guard let size = UInt32(exactly: entry.data.count) else {
            throw failure("ZIP entryが4 GiB以上です: \(entry.path)")
        }
        guard let localHeaderOffset = UInt32(exactly: archiveOffset) else {
            throw failure("ZIP64が必要なサイズです")
        }
        return CentralRecord(
            name: name,
            nameLength: nameLength,
            crc32: CRC32.checksum(entry.data),
            size: size,
            localHeaderOffset: localHeaderOffset
        )
    }

    private static func appendLocalHeader(
        to data: inout Data,
        nameLength: UInt16,
        crc32: UInt32,
        size: UInt32
    ) {
        data.appendLittleEndian(UInt32(0x0403_4B50))
        data.appendLittleEndian(version20)
        data.appendLittleEndian(utf8Flag)
        data.appendLittleEndian(storedMethod)
        data.appendLittleEndian(fixedDOSTime)
        data.appendLittleEndian(fixedDOSDate)
        data.appendLittleEndian(crc32)
        data.appendLittleEndian(size)
        data.appendLittleEndian(size)
        data.appendLittleEndian(nameLength)
        data.appendLittleEndian(UInt16(0)) // extra field length
    }

    private static func appendCentralHeader(to data: inout Data, record: CentralRecord) {
        data.appendLittleEndian(UInt32(0x0201_4B50))
        data.appendLittleEndian(version20) // made by: ZIP 2.0 / MS-DOS
        data.appendLittleEndian(version20)
        data.appendLittleEndian(utf8Flag)
        data.appendLittleEndian(storedMethod)
        data.appendLittleEndian(fixedDOSTime)
        data.appendLittleEndian(fixedDOSDate)
        data.appendLittleEndian(record.crc32)
        data.appendLittleEndian(record.size)
        data.appendLittleEndian(record.size)
        data.appendLittleEndian(record.nameLength)
        data.appendLittleEndian(UInt16(0)) // extra field length
        data.appendLittleEndian(UInt16(0)) // comment length
        data.appendLittleEndian(UInt16(0)) // disk number
        data.appendLittleEndian(UInt16(0)) // internal attributes
        data.appendLittleEndian(UInt32(0)) // external attributes
        data.appendLittleEndian(record.localHeaderOffset)
        data.append(record.name)
    }

    private static func appendEndOfCentralDirectory(
        to data: inout Data,
        entryCount: UInt16,
        centralDirectorySize: UInt32,
        centralDirectoryOffset: UInt32
    ) {
        data.appendLittleEndian(UInt32(0x0605_4B50))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(entryCount)
        data.appendLittleEndian(entryCount)
        data.appendLittleEndian(centralDirectorySize)
        data.appendLittleEndian(centralDirectoryOffset)
        data.appendLittleEndian(UInt16(0)) // archive comment length
    }

    private static func failure(_ reason: String) -> ExportError {
        .renderingFailed(format: .epub, reason: reason)
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0 ..< 256).map { value in
        var remainder = UInt32(value)
        for _ in 0 ..< 8 {
            remainder = (remainder & 1) == 1
                ? 0xEDB8_8320 ^ (remainder >> 1)
                : remainder >> 1
        }
        return remainder
    }

    static func checksum(_ data: Data) -> UInt32 {
        var checksum: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((checksum ^ UInt32(byte)) & 0xFF)
            checksum = table[index] ^ (checksum >> 8)
        }
        return checksum ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
