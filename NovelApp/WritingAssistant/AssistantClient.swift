import Foundation
import NovelWorkspaceUI

/// Redirects must never forward an author's text or credential to another endpoint.
final class AssistantRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_: URLSession, task _: URLSessionTask,
                    willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest _: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

extension AssistantClient {
    @MainActor
    static func send(_ original: URLRequest, maxSeconds: Double = AssistantRuntimeTiming.defaultChatMaxSeconds,
                     progress: @escaping @MainActor (AssistantProgress) -> Void = { _ in }) async throws -> String {
        #if FUMINIWA_TEST_COMPOSITION
        throw AssistantError.invalidConfiguration
        #else
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = maxSeconds
        configuration.timeoutIntervalForResource = maxSeconds
        let session = URLSession(configuration: configuration, delegate: AssistantRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = original
        request.timeoutInterval = maxSeconds
        guard let data = request.httpBody,
              var body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AssistantError.invalidConfiguration }
        body["stream"] = true
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AssistantError.invalidResponse }
        if !(200 ..< 300).contains(http.statusCode) {
            let errorData = try await boundedData(bytes, limit: 64000)
            guard AssistantStream.rejectsStreaming(status: http.statusCode, data: errorData) else { throw AssistantError.http(http.statusCode) }
            progress(AssistantProgress(phase: .elapsedOnly))
            body["stream"] = false
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (fallbackBytes, fallbackResponse) = try await session.bytes(for: request)
            guard let fallbackHTTP = fallbackResponse as? HTTPURLResponse else { throw AssistantError.invalidResponse }
            guard (200 ..< 300).contains(fallbackHTTP.statusCode) else { throw AssistantError.http(fallbackHTTP.statusCode) }
            return try await decode(boundedData(fallbackBytes))
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
            progress(AssistantProgress(phase: .elapsedOnly))
            return try await decode(boundedData(bytes))
        }
        var decoder = AssistantStream(), line = Data(), previousCR = false
        for try await byte in bytes {
            try Task.checkCancellation()
            if byte == 10, previousCR {
                previousCR = false; continue
            }
            previousCR = byte == 13
            if byte == 10 || byte == 13 {
                guard let string = String(data: line, encoding: .utf8) else { throw AssistantError.invalidResponse }
                line.removeAll(keepingCapacity: true)
                if try decoder.consume(line: string) {
                    progress(decoder.progress)
                }
                if let result = decoder.result {
                    return result
                }
            } else {
                line.append(byte)
                guard line.count <= 8_000_000 else { throw AssistantError.tooLarge }
            }
        }
        return try decoder.completed()
        #endif
    }

    private static func boundedData(_ bytes: URLSession.AsyncBytes, limit: Int = 8_000_000) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw AssistantError.tooLarge }
            data.append(byte)
        }
        return data
    }

    static func models(apiKey: String) async throws -> [String] {
        #if FUMINIWA_TEST_COMPOSITION
        throw AssistantError.invalidConfiguration
        #else
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral, delegate: AssistantRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AssistantError.invalidResponse }
        guard response.statusCode == 200 else { throw AssistantError.http(response.statusCode) }
        return try decodeModels(data)
        #endif
    }
}
