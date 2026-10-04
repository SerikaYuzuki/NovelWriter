import Foundation

public struct AssistantProgress: Equatable, Sendable {
    public enum Phase: String, Sendable { case queued, working, receiving, elapsedOnly }
    public var phase: Phase
    public var characters: Int
    public init(phase: Phase, characters: Int = 0) {
        self.phase = phase; self.characters = characters
    }
}

/// SSE frames are consumed privately. Only terminal output can leave the decoder.
public struct AssistantStream {
    private var dataLines: [String] = []
    private var frameBytes = 0
    private var text = ""
    private var finishReason: String?
    private var textBytes = 0
    private var tail = ""
    public private(set) var progress = AssistantProgress(phase: .queued)
    public private(set) var result: String?
    public init() {}

    /// Returns true for a complete event, including comments/keepalives.
    public mutating func consume(line: String) throws -> Bool {
        guard result == nil else { return false }
        frameBytes += line.utf8.count
        guard frameBytes <= 8_000_000 else { throw AssistantError.tooLarge }
        if line.hasPrefix(":") {
            frameBytes -= line.utf8.count
            return true
        }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.first == " " {
                value.removeFirst()
            }
            dataLines.append(value)
        }
        guard line.isEmpty else { return false }
        frameBytes = 0
        guard !dataLines.isEmpty else { return false }
        let data = dataLines.joined(separator: "\n"); dataLines.removeAll(keepingCapacity: true)
        try consumeEvent(data)
        return true
    }

    private mutating func consumeEvent(_ data: String) throws {
        if data == "[DONE]" {
            guard finishReason != nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AssistantError.unfinishedOutput
            }
            result = text + (finishReason == "length" ? "\n\n（出力上限に達したため、回答は途中までです。）" : "")
            return
        }
        guard let event = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else {
            throw AssistantError.invalidResponse
        }
        if event["error"] != nil || event["type"] as? String == "error" {
            throw AssistantError.apiFailure
        }
        switch event["type"] as? String {
        case "response.created", "response.queued": progress.phase = .queued
        case "response.in_progress": progress.phase = .working
        case "response.output_text.delta":
            if let delta = event["delta"] as? String {
                try append(delta)
            }
        case "response.completed", "response.incomplete":
            guard let response = event["response"] as? [String: Any] else { throw AssistantError.invalidResponse }
            result = try AssistantClient.decode(JSONSerialization.data(withJSONObject: response))
        case "response.failed": throw AssistantError.apiFailure
        default: try consumeChat(event)
        }
    }

    private mutating func consumeChat(_ event: [String: Any]) throws {
        guard let choices = event["choices"] as? [[String: Any]],
              let choice = choices.first(where: { ($0["index"] as? Int ?? 0) == 0 }) else { return }
        if let delta = choice["delta"] as? [String: Any] {
            if progress.phase == .queued {
                progress.phase = .working
            }
            if let content = delta["content"] as? String {
                try append(content)
            }
        }
        if let reason = choice["finish_reason"] as? String {
            if reason == "content_filter" {
                throw AssistantError.filteredOutput
            }
            guard ["stop", "length"].contains(reason) else { throw AssistantError.unfinishedOutput }
            finishReason = reason
        }
    }

    private mutating func append(_ delta: String) throws {
        textBytes += delta.utf8.count
        guard textBytes <= 8_000_000 else { throw AssistantError.tooLarge }
        let boundary = tail + delta
        let characters = progress.characters + boundary.count - tail.count
        tail = boundary.last.map(String.init) ?? ""
        text += delta
        progress = AssistantProgress(phase: .receiving, characters: characters)
    }

    public func completed() throws -> String {
        guard let result else { throw AssistantError.unfinishedOutput }; return result
    }

    /// Fallback is safe only after an explicit rejection of the streaming parameter.
    public static func rejectsStreaming(status: Int, data: Data) -> Bool {
        guard [400, 422, 501].contains(status),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = body["error"] as? [String: Any] else { return false }
        let param = error["param"] as? String ?? ""
        let message = (error["message"] as? String ?? "").lowercased()
        return param == "stream" || (message.contains("stream") && ["unsupported", "not supported", "not support", "unknown", "not allowed"].contains { message.contains($0) })
    }
}
