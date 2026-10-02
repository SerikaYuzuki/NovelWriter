import Foundation
import NovelSyncV2
import Testing

@Test(arguments: [
    "2026-09-12T06:00:00Z", "2026-09-12T06:00:00+00:00",
    "2026-09-12T06:00:00.123+00:00", "2026-09-12T06:00:00.123456+00:00",
    "2026-09-12T06:00:00.123456789+00:00", "2026-09-12T15:00:00.123456+09:00"
])
func serverExpiryAcceptsRFC3339(_ value: String) {
    let date = SyncV2Timestamp.parse(value)
    #expect(date != nil)
    #expect(abs((date?.timeIntervalSince1970 ?? 0) - 1_789_192_800) < 1)
}

@Test func serverExpiryRejectsInvalidText() {
    #expect(SyncV2Timestamp.parse("not-a-date") == nil)
}
