import Foundation
import NovelSync

/// 検証済み端末inventoryを、起動画面が読める棚行へ変換するための値。
///
/// packageのURLやCloudKit型は保持せず、AppStateのsession／I/O状態から分離する。
struct StartupVerifiedLocalLibraryItem {
    let record: DeviceSyncLocalLibraryRecord?
    let attestation: DeviceSyncLocalPackageAttestation?
    let row: StartupLibraryWork
}

struct StartupVerifiedLocalLibrarySnapshot {
    let items: [SyncWorkID: StartupVerifiedLocalLibraryItem]

    var rows: [StartupLibraryWork] {
        items.values.map(\.row)
    }
}

/// Startup libraryの表示用projectionだけを所有するnamespace。
/// remote refreshやpackage I/Oをここへ持ち込まない。
enum StartupLibraryProjection {
    static func addOfflineResumableRows(
        _ workIDs: [SyncWorkID],
        to existingRows: [StartupLibraryWork]
    ) -> [StartupLibraryWork] {
        var rows = Dictionary(uniqueKeysWithValues: existingRows.map { row in
            (row.reference, row)
        })
        for workID in workIDs {
            let reference = StartupLibraryWorkReference.cloudWork(workID.rawValue)
            guard rows[reference] == nil else { continue }
            rows[reference] = StartupLibraryWork(
                reference: reference,
                // Domain intentionally exposes identity only. A title is not carried
                // across an unverified account boundary.
                title: "このMacへの保存を再開する作品",
                updatedAt: nil,
                availability: .remotePending
            )
        }
        return Array(rows.values)
    }

    static func connection(
        _ connection: DeviceSyncLibraryConnection
    ) -> StartupLibraryConnection {
        switch connection {
        case .available:
            .available
        case .offline:
            .offline
        case .accountRequired:
            .accountRequired
        case .differentAccount:
            .differentAccount
        }
    }

    static func sort(
        _ lhs: StartupLibraryWork,
        _ rhs: StartupLibraryWork
    ) -> Bool {
        switch (lhs.updatedAt, rhs.updatedAt) {
        case let (left?, right?) where left != right:
            left > right
        case (nil, _?):
            false
        case (_?, nil):
            true
        default:
            lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
        }
    }
}
