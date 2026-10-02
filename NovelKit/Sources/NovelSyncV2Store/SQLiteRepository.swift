import Foundation
import NovelCore
import NovelSyncV2

/// Synchronous, actor-confined access to the store's shared executor.
/// Repository mutations called from a Store transaction use that already-open
/// transaction; repositories never begin, commit, or roll back transactions.
/// Helpers named `...Transaction` / `...InTransaction` and persistence helpers
/// used by Store orchestration assume its transaction is open. Standalone
/// operations retain their existing autocommit behavior.
protocol SQLiteRepository {
    var executor: SQLiteExecutor { get }
}

extension SQLiteRepository {
    func exec(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        try executor.exec(sql, bindings)
    }

    func query(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
        try executor.query(sql, bindings)
    }

    func queryRows<Row: SQLiteRowDecodable>(
        _: Row.Type, _ sql: String, _ bindings: [SQLiteValue] = []
    ) throws -> [Row] {
        try query(sql, bindings).map(Row.init)
    }

    func changes() throws -> Int {
        try executor.changes()
    }
}

extension SQLiteRepository {
    var workRepository: WorkRepository {
        WorkRepository(executor: executor)
    }

    var outboxRepository: OutboxRepository {
        OutboxRepository(executor: executor)
    }

    var inboxRepository: InboxRepository {
        InboxRepository(executor: executor)
    }

    var conflictRepository: ConflictRepository {
        ConflictRepository(executor: executor)
    }

    var accountRepository: AccountRepository {
        AccountRepository(executor: executor)
    }

    var deletionRepository: DeletionRepository {
        DeletionRepository(executor: executor)
    }
}

extension LocalSyncV2Store {
    var workRepository: WorkRepository {
        WorkRepository(executor: executor)
    }

    var outboxRepository: OutboxRepository {
        OutboxRepository(executor: executor)
    }

    var inboxRepository: InboxRepository {
        InboxRepository(executor: executor)
    }

    var conflictRepository: ConflictRepository {
        ConflictRepository(executor: executor)
    }

    var accountRepository: AccountRepository {
        AccountRepository(executor: executor)
    }

    var deletionRepository: DeletionRepository {
        DeletionRepository(executor: executor)
    }
}
