import Foundation
@testable import FUMINIWA
import NovelSync
import Testing

@Suite("Startup library projection")
struct StartupLibraryProjectionTests {
    @Test("棚projectionは更新日時を優先しnilを最後へ置く")
    func sortsRecentRowsBeforeUndatedRows() {
        let older = StartupLibraryWork(
            reference: .cloudWork(UUID()),
            title: "古い作品",
            updatedAt: Date(timeIntervalSince1970: 1),
            availability: .localPending
        )
        let newer = StartupLibraryWork(
            reference: .cloudWork(UUID()),
            title: "新しい作品",
            updatedAt: Date(timeIntervalSince1970: 2),
            availability: .localPending
        )
        let undated = StartupLibraryWork(
            reference: .cloudWork(UUID()),
            title: "名称で比較",
            updatedAt: nil,
            availability: .localPending
        )

        let sorted = [undated, older, newer].sorted(by: StartupLibraryProjection.sort)

        #expect(sorted == [newer, older, undated])
    }

    @Test("offline resume行は既存行を上書きせずidentityだけを表示する")
    func addsOfflineRowsWithoutLeakingTitles() {
        let workID = SyncWorkID(rawValue: UUID())
        let existing = StartupLibraryWork(
            reference: .cloudWork(workID.rawValue),
            title: "検証済み作品",
            updatedAt: Date(),
            availability: .cachedRemote
        )

        let rows = StartupLibraryProjection.addOfflineResumableRows(
            [workID, SyncWorkID(rawValue: UUID())],
            to: [existing]
        )

        #expect(rows.contains(existing))
        #expect(rows.count == 2)
        #expect(rows.contains { $0.title == "このMacへの保存を再開する作品" })
    }

    @Test("remote connectionの表示値はdomain値を一対一で写像する")
    func mapsRemoteConnections() {
        #expect(StartupLibraryProjection.connection(.available) == .available)
        #expect(StartupLibraryProjection.connection(.offline) == .offline)
        #expect(StartupLibraryProjection.connection(.accountRequired) == .accountRequired)
        #expect(StartupLibraryProjection.connection(.differentAccount) == .differentAccount)
    }
}
