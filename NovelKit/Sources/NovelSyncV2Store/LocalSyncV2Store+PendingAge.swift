import Foundation
import NovelSyncV2

public extension LocalSyncV2Store {
    /// The first unreceived intent survives coalescing and process restarts.
    func oldestUnreceivedChange(workID: WorkID, scope: V2LocalWorkScope) throws -> Date? {
        let rows = try query("""
        SELECT MIN(created_at) FROM sync_intents
        WHERE work_id=? AND scope_kind='bound'
          AND status IN ('pending','sealed','quarantined','parked')
          AND NOT EXISTS (SELECT 1 FROM intent_subsumptions s WHERE s.intent_id=sync_intents.intent_id)
        """ + scope.intentPredicateSQL, [.text(workID.description)] + scope.intentPredicateValues)
        guard let text = try rows.first?.scalar.text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: text) {
            return value
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text) ?? .distantFuture
    }
}
