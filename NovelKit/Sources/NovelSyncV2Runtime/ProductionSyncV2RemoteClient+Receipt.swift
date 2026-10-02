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
        try Self.validateTransportStatus(response)
        guard http.statusCode == 200,
              httpContentType(response) == mediaType,
              http.value(forHTTPHeaderField: "Cache-Control")?.lowercased() == "no-store",
              http.value(forHTTPHeaderField: "Pragma")?.lowercased() == "no-cache" else {
            throw SyncV2Failure.receiptMismatch
        }
        let workID = try remoteClientWorkID(for: command)
        do {
            _ = try validateSyncV2ReceiptEnvelope(
                data, commandID: command.commandId, commandKind: command.commandKind,
                requestDigest: command.requestDigest, workID: workID,
                expectation: .response(status: receipt.responseStatus, result: receipt.result.rawValue,
                                       canonicalBytes: receipt.canonicalResponse)
            )
        } catch {
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
