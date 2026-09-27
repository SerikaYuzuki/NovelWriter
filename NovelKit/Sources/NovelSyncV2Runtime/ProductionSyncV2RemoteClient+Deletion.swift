import Foundation
import NovelSyncV2
import NovelSyncV2Application
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension ProductionSyncV2RemoteClient {
    func deleteWork(workID: WorkID, binding: SyncV2AccountScopeBinding) async throws {
        let session = try await loadSession()
        guard binding.accountID == session.accountID,
              binding.accountFence == session.accountFence,
              binding.serverInstanceID == session.serverInstanceID.uuidString.lowercased(),
              binding.protocolEpoch == 2 else { throw SyncV2Failure.accountFenceChanged }
        let wireBinding = SealedCommand.Binding(
            accountFence: binding.accountFence,
            accountId: binding.accountID,
            protocolEpoch: binding.protocolEpoch,
            serverInstanceId: binding.serverInstanceID
        )
        var request = URLRequest(url: origin.url.appendingPathComponent("v2/works/\(workID.description)"))
        request.httpMethod = "DELETE"
        addHeaders(&request, session: session, binding: wireBinding)
        let (data, response) = try await requestData(request, session: session)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              httpContentType(response) == mediaType,
              http.value(forHTTPHeaderField: "Cache-Control")?.lowercased() == "no-store",
              http.value(forHTTPHeaderField: "Pragma")?.lowercased() == "no-cache",
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["result", "workId"],
              object["result"] as? String == "deleted",
              object["workId"] as? String == workID.description else { throw SyncV2Failure.receiptMismatch }
    }
}
