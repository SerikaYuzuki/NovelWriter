import Foundation

struct AccountBindingRow: SQLiteRowDecodable {
    static let columns = """
    work_id,server_instance_id,protocol_epoch,account_id,account_fence
    """
    let workID: String?
    let serverInstanceID: String?
    let protocolEpoch: Int64?
    let accountID: String?
    let accountFence: String?

    init(_ row: SQLiteRow) throws {
        workID = try row.text("work_id")
        serverInstanceID = try row.text("server_instance_id")
        protocolEpoch = try row.int64("protocol_epoch")
        accountID = try row.text("account_id")
        accountFence = try row.text("account_fence")
    }
}

struct ActiveAccountBindingRow: SQLiteRowDecodable {
    static let columns = """
    account_id,account_fence,server_instance_id,protocol_epoch
    """
    let accountID: String?
    let accountFence: String?
    let serverInstanceID: String?
    let protocolEpoch: Int64?

    init(_ row: SQLiteRow) throws {
        accountID = try row.text("account_id")
        accountFence = try row.text("account_fence")
        serverInstanceID = try row.text("server_instance_id")
        protocolEpoch = try row.int64("protocol_epoch")
    }
}
