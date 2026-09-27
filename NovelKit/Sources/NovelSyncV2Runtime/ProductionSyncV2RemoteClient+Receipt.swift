import Foundation
import NovelAuth
import NovelSyncV2
import NovelSyncV2Application

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension ProductionSyncV2RemoteClient {
    /// Store acknowledgement requires the server's durable receipt envelope,
    /// not the mutation response. Preserve and compare the exact response bytes.
    func readBack(
        _ receipt: SyncV2ReceiptReadback,
        command: SealedCommand,
        session: FuminiwaSession
    ) async throws -> SyncV2ReceiptReadback {
        let url = origin.url.appendingPathComponent("v2/receipts/\(command.commandId.uuidString.lowercased())")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addHeaders(&request, session: session, binding: command.binding)
        let (data, response) = try await requestData(request, session: session)
        guard let http = response as? HTTPURLResponse else {
            throw SyncV2Failure.retryable(.lostResponse)
        }
        if [408, 429].contains(http.statusCode) || (500 ... 599).contains(http.statusCode) {
            throw SyncV2Failure.retryable(.serverUnavailable)
        }
        if http.statusCode == 401 {
            throw SyncV2Failure.authenticationRequired
        }
        if http.statusCode == 403 {
            throw SyncV2Failure.accountFenceChanged
        }
        guard http.statusCode == 200,
              httpContentType(response) == mediaType,
              http.value(forHTTPHeaderField: "Cache-Control")?.lowercased() == "no-store",
              http.value(forHTTPHeaderField: "Pragma")?.lowercased() == "no-cache" else {
            throw SyncV2Failure.receiptMismatch
        }
        let workID = try remoteClientWorkID(for: command)
        try CanonicalJSON.validate(data)
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(envelope.keys) == Set([
                  "canonicalResponseBase64URL", "commandId", "commandKind", "originalResponseStatus",
                  "originalResult", "readBack", "requestDigest", "result", "workId"
              ]),
              envelope["commandId"] as? String == command.commandId.uuidString.lowercased(),
              envelope["commandKind"] as? String == command.commandKind,
              envelope["requestDigest"] as? String == command.requestDigest.rawValue,
              envelope["workId"] as? String == workID.description,
              envelope["result"] as? String == "noChanges",
              envelope["originalResult"] as? String == receipt.result.rawValue,
              envelope["originalResponseStatus"] as? Int == receipt.responseStatus,
              let encoded = envelope["canonicalResponseBase64URL"] as? String,
              encoded == receipt.canonicalResponse.base64EncodedString()
              .replacingOccurrences(of: "+", with: "-")
              .replacingOccurrences(of: "/", with: "_")
              .replacingOccurrences(of: "=", with: ""),
              let predicates = envelope["readBack"] as? [String: Bool],
              predicates == [
                  "accountMatched": true, "commandDigestMatched": true, "resourceMatched": true,
                  "headMatched": true, "stateMatched": true
              ] else {
            throw SyncV2Failure.receiptMismatch
        }
        return SyncV2ReceiptReadback(
            commandID: receipt.commandID,
            requestDigest: receipt.requestDigest,
            responseStatus: receipt.responseStatus,
            canonicalResponse: data,
            predicates: receipt.predicates,
            result: receipt.result,
            conflict: receipt.conflict,
            remoteHead: receipt.remoteHead
        )
    }
}
