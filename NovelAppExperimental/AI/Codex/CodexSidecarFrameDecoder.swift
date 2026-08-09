import Foundation

struct CodexSidecarFrameDecoder: Sendable {
    static let maximumFrameBytes = 262_144
    static let maximumStreamBytes = 524_288

    private var buffer = Data()
    private var isUnavailable = false
    private var acceptedByteCount = 0

    var isAtFrameBoundary: Bool {
        buffer.isEmpty
    }

    mutating func append(_ chunk: Data) throws -> [String] {
        guard !isUnavailable else {
            throw CodexSidecarLocalError.decoderUnavailable
        }

        do {
            let total = acceptedByteCount.addingReportingOverflow(chunk.count)
            let actual = total.overflow ? Int.max : total.partialValue
            guard !total.overflow, actual <= Self.maximumStreamBytes else {
                throw CodexSidecarLocalError.streamByteLimitExceeded(
                    limit: Self.maximumStreamBytes,
                    actual: actual
                )
            }
            acceptedByteCount = actual
            return try appendValidating(chunk)
        } catch {
            isUnavailable = true
            buffer.removeAll(keepingCapacity: false)
            throw error
        }
    }

    mutating func finish() throws {
        guard !isUnavailable else {
            throw CodexSidecarLocalError.decoderUnavailable
        }
        guard buffer.isEmpty else {
            isUnavailable = true
            buffer.removeAll(keepingCapacity: false)
            throw CodexSidecarLocalError.unterminatedFrame
        }
        isUnavailable = true
    }

    private mutating func appendValidating(_ chunk: Data) throws -> [String] {
        var frames: [String] = []
        var segmentStart = chunk.startIndex

        while segmentStart < chunk.endIndex {
            guard let lineFeedIndex = chunk[segmentStart...].firstIndex(of: 0x0A) else {
                break
            }
            try appendSegment(chunk[segmentStart ..< lineFeedIndex])
            try frames.append(completeFrame())
            segmentStart = chunk.index(after: lineFeedIndex)
        }

        if segmentStart < chunk.endIndex {
            try appendSegment(chunk[segmentStart...])
        }
        return frames
    }

    private mutating func appendSegment(_ segment: Data.SubSequence) throws {
        if segment.contains(0x0D) {
            throw CodexSidecarLocalError.carriageReturnNotAllowed
        }
        let total = buffer.count.addingReportingOverflow(segment.count)
        let actual = total.overflow ? Int.max : total.partialValue
        guard !total.overflow, actual <= Self.maximumFrameBytes else {
            throw CodexSidecarLocalError.frameTooLarge(
                limit: Self.maximumFrameBytes,
                actual: actual
            )
        }
        buffer.append(contentsOf: segment)
    }

    private mutating func completeFrame() throws -> String {
        guard !buffer.isEmpty else {
            throw CodexSidecarLocalError.emptyFrame
        }
        guard !buffer.starts(with: [0xEF, 0xBB, 0xBF]) else {
            throw CodexSidecarLocalError.byteOrderMarkNotAllowed
        }
        guard let frame = String(data: buffer, encoding: .utf8) else {
            throw CodexSidecarLocalError.invalidUTF8
        }
        buffer.removeAll(keepingCapacity: true)
        return frame
    }
}
