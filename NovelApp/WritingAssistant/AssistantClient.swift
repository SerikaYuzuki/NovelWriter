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
    static func send(_ request: URLRequest) async throws -> String {
        #if FUMINIWA_TEST_COMPOSITION
        throw AssistantError.invalidConfiguration
        #else
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration, delegate: AssistantRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw AssistantError.invalidResponse }
        guard (200 ..< 300).contains(response.statusCode) else { throw AssistantError.http(response.statusCode) }
        return try decode(data)
        #endif
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
