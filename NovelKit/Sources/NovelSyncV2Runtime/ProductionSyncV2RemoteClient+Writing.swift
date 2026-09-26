import Foundation
import NovelSyncV2
import NovelSyncV2Application
import NovelWritingSupport

extension ProductionSyncV2RemoteClient {
    func writingRecordPage(workID: UUID?, after: Int64, binding: SyncV2AccountScopeBinding) async throws -> WritingRecordPage {
        var components = URLComponents(url: origin.url.appendingPathComponent("v2/assistant/records"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "after", value: String(after))]
        if let workID {
            components.queryItems?.append(URLQueryItem(name: "workId", value: workID.uuidString.lowercased()))
        }
        return try await writingRequest(URLRequest(url: components.url!), binding: binding)
    }

    func appendWritingRecord(_ record: WritingRecord, binding: SyncV2AccountScopeBinding) async throws -> WritingEnvelope {
        var request = URLRequest(url: origin.url.appendingPathComponent("v2/assistant/records"))
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(record)
        return try await writingRequest(request, binding: binding)
    }

    private func writingRequest<T: Decodable>(_ original: URLRequest, binding: SyncV2AccountScopeBinding) async throws -> T {
        let current = try await loadSession()
        guard current.accountID == binding.accountID, current.accountFence == binding.accountFence,
              current.serverInstanceID.uuidString.lowercased() == binding.serverInstanceID else { throw WritingError.changedScope }
        var request = original
        addHeaders(&request, session: current, binding: SealedCommand.Binding(accountFence: binding.accountFence,
                                                                              accountId: binding.accountID, protocolEpoch: binding.protocolEpoch,
                                                                              serverInstanceId: binding.serverInstanceID))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await requestData(request, session: current)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= 16 * 1024 * 1024 else { throw SyncV2Failure.fatal(.remoteDataUnavailable) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
