import Foundation
import NovelCore

struct TestZIPArchive {
    struct LocalEntry {
        let path: String
        let localHeaderOffset: Int
        let versionNeeded: UInt16
        let flags: UInt16
        let compressionMethod: UInt16
        let crc32: UInt32
        let extraField: Data
        let dataOffset: Int
        let data: Data
    }

    struct CentralEntry {
        let path: String
        let flags: UInt16
        let compressionMethod: UInt16
        let localHeaderOffset: UInt32
    }

    let localEntries: [LocalEntry]
    let centralEntries: [CentralEntry]
    let centralDirectoryOffset: Int
    let centralDirectorySize: Int

    init(data: Data) throws {
        let bytes = [UInt8](data)
        let endOffset = try Self.findEndOfCentralDirectory(in: bytes)
        let entryCount = try Int(Self.uint16(bytes, at: endOffset + 10))
        centralDirectorySize = try Int(Self.uint32(bytes, at: endOffset + 12))
        centralDirectoryOffset = try Int(Self.uint32(bytes, at: endOffset + 16))

        let parsedLocalEntries = try Self.parseLocalEntries(
            bytes,
            centralDirectoryOffset: centralDirectoryOffset
        )
        let centralResult = try Self.parseCentralEntries(
            bytes,
            centralDirectoryOffset: centralDirectoryOffset,
            entryCount: entryCount
        )
        let expectedCentralEnd = centralDirectoryOffset + centralDirectorySize
        let directoryIsValid = centralResult.endOffset == expectedCentralEnd
            && centralResult.endOffset == endOffset
            && parsedLocalEntries.count == entryCount
        guard directoryIsValid else { throw TestZIPError.invalidCentralDirectory }

        localEntries = parsedLocalEntries
        centralEntries = centralResult.entries
    }

    private static func parseLocalEntries(
        _ bytes: [UInt8],
        centralDirectoryOffset: Int
    ) throws -> [LocalEntry] {
        var parsedLocalEntries: [LocalEntry] = []
        var localOffset = 0
        while localOffset < centralDirectoryOffset {
            guard try Self.uint32(bytes, at: localOffset) == 0x0403_4B50 else {
                throw TestZIPError.invalidSignature(localOffset)
            }
            let version = try Self.uint16(bytes, at: localOffset + 4)
            let flags = try Self.uint16(bytes, at: localOffset + 6)
            let method = try Self.uint16(bytes, at: localOffset + 8)
            let crc32 = try Self.uint32(bytes, at: localOffset + 14)
            let compressedSize = try Int(Self.uint32(bytes, at: localOffset + 18))
            let nameLength = try Int(Self.uint16(bytes, at: localOffset + 26))
            let extraLength = try Int(Self.uint16(bytes, at: localOffset + 28))
            let nameStart = localOffset + 30
            let extraStart = nameStart + nameLength
            let dataStart = extraStart + extraLength
            let dataEnd = dataStart + compressedSize
            let path = try Self.string(bytes, range: nameStart ..< extraStart)
            let extra = try Self.data(bytes, range: extraStart ..< dataStart)
            let contents = try Self.data(bytes, range: dataStart ..< dataEnd)
            parsedLocalEntries.append(
                LocalEntry(
                    path: path,
                    localHeaderOffset: localOffset,
                    versionNeeded: version,
                    flags: flags,
                    compressionMethod: method,
                    crc32: crc32,
                    extraField: extra,
                    dataOffset: dataStart,
                    data: contents
                )
            )
            localOffset = dataEnd
        }
        guard localOffset == centralDirectoryOffset else {
            throw TestZIPError.invalidCentralDirectory
        }
        return parsedLocalEntries
    }

    private static func parseCentralEntries(
        _ bytes: [UInt8],
        centralDirectoryOffset: Int,
        entryCount: Int
    ) throws -> (entries: [CentralEntry], endOffset: Int) {
        var parsedCentralEntries: [CentralEntry] = []
        var centralOffset = centralDirectoryOffset
        for _ in 0 ..< entryCount {
            guard try Self.uint32(bytes, at: centralOffset) == 0x0201_4B50 else {
                throw TestZIPError.invalidSignature(centralOffset)
            }
            let flags = try Self.uint16(bytes, at: centralOffset + 8)
            let method = try Self.uint16(bytes, at: centralOffset + 10)
            let nameLength = try Int(Self.uint16(bytes, at: centralOffset + 28))
            let extraLength = try Int(Self.uint16(bytes, at: centralOffset + 30))
            let commentLength = try Int(Self.uint16(bytes, at: centralOffset + 32))
            let localHeaderOffset = try Self.uint32(bytes, at: centralOffset + 42)
            let nameStart = centralOffset + 46
            let nameEnd = nameStart + nameLength
            try parsedCentralEntries.append(
                CentralEntry(
                    path: Self.string(bytes, range: nameStart ..< nameEnd),
                    flags: flags,
                    compressionMethod: method,
                    localHeaderOffset: localHeaderOffset
                )
            )
            centralOffset = nameEnd + extraLength + commentLength
        }
        return (parsedCentralEntries, centralOffset)
    }

    func data(named path: String) throws -> Data {
        guard let entry = localEntries.first(where: { $0.path == path }) else {
            throw TestZIPError.missingEntry(path)
        }
        return entry.data
    }

    func string(named path: String) throws -> String {
        let contents = try data(named: path)
        guard let string = String(bytes: contents, encoding: .utf8) else {
            throw TestZIPError.invalidUTF8(path)
        }
        return string
    }

    private static func findEndOfCentralDirectory(in bytes: [UInt8]) throws -> Int {
        guard bytes.count >= 22 else { throw TestZIPError.invalidCentralDirectory }
        let lowerBound = max(0, bytes.count - 65557)
        for offset in stride(from: bytes.count - 22, through: lowerBound, by: -1) {
            guard try uint32(bytes, at: offset) == 0x0605_4B50 else { continue }
            return offset
        }
        throw TestZIPError.invalidCentralDirectory
    }

    private static func uint16(_ bytes: [UInt8], at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { throw TestZIPError.outOfBounds }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { throw TestZIPError.outOfBounds }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func string(_ bytes: [UInt8], range: Range<Int>) throws -> String {
        let data = try data(bytes, range: range)
        guard let value = String(bytes: data, encoding: .utf8) else {
            throw TestZIPError.invalidUTF8("ZIP entry name")
        }
        return value
    }

    private static func data(_ bytes: [UInt8], range: Range<Int>) throws -> Data {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else {
            throw TestZIPError.outOfBounds
        }
        return Data(bytes[range])
    }
}

enum TestZIPError: Error {
    case invalidSignature(Int)
    case invalidCentralDirectory
    case invalidUTF8(String)
    case missingEntry(String)
    case outOfBounds
}

func makeEPUBFixture() -> NovelDocument {
    let identifier = UUID(
        uuid: (
            0x12, 0x34, 0x56, 0x78,
            0x12, 0x34, 0x56, 0x78,
            0x90, 0xAB, 0xCD, 0xEF,
            0x12, 0x34, 0x56, 0x78
        )
    )
    return NovelDocument(
        id: identifier,
        title: "宇宙 & <航路> \"改題\" 😀",
        synopsis: "EPUBには含めないあらすじ",
        chapters: [
            Chapter(
                title: "第一章 & <始まり>",
                episodes: [
                    Episode(
                        title: "出会い \"A&B\" '再会'",
                        content: "　先頭<&>\r\n\r次の段落 😀\r\n"
                    ),
                    Episode(title: " \n　", content: "")
                ]
            ),
            Chapter(title: "\n　", episodes: []),
            Chapter(
                title: "空話章",
                episodes: [Episode(title: "空話", content: "")]
            )
        ],
        worldNotes: [WorldNote(title: "非出力", content: "秘密")]
    )
}

func appearsInOrder(_ fragments: [String], in value: String) -> Bool {
    var searchStart = value.startIndex
    for fragment in fragments {
        guard let range = value.range(of: fragment, range: searchStart ..< value.endIndex) else {
            return false
        }
        searchStart = range.upperBound
    }
    return true
}

func occurrenceCount(of fragment: String, in value: String) -> Int {
    value.components(separatedBy: fragment).count - 1
}
