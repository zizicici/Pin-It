//
//  TimestampedRecord.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/17.
//

import GRDB
import Foundation

/// A record type that tracks its creation and modification dates. See
/// <https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/recordtimestamps>
protocol TimestampedRecord: MutablePersistableRecord {
    var id: Int64? { get set }
    var creationTime: Int64? { get set }
    var modificationTime: Int64? { get set }
}

extension TimestampedRecord {
    /// By default, `TimestampedRecord` types set `creationDate` and
    /// `modificationTime` to the transaction date, if they are nil,
    /// before insertion.
    ///
    /// `TimestampedRecord` types that customize the `willInsert`
    /// persistence callback should call `initializeTimestamps` from
    /// their implementation.
    mutating func willInsert(_ db: Database) throws {
        try initializeTimestamps(db)
    }
    
    /// Sets `creationDate` and `modificationTime` to the transaction date,
    /// if they are nil.
    ///
    /// It is called automatically before insertion, if your type does not
    /// customize the `willInsert` persistence callback. If you customize
    /// this callback, call `initializeTimestamps` from your implementation.
    mutating func initializeTimestamps(_ db: Database) throws {
        if creationTime == nil {
            creationTime = try db.transactionDate.millisecondsSince1970
        }
        if modificationTime == nil {
            modificationTime = try db.transactionDate.millisecondsSince1970
        }
    }
    
    /// Sets `modificationTime`, and executes an `UPDATE` statement
    /// on all columns.
    ///
    /// - parameter modificationTime: The modification date. If nil, the
    ///   transaction date is used.
    mutating func updateWithTimestamp(_ db: Database, modificationTime: Date? = nil) throws {
        self.modificationTime = try nextModificationTime(db, modificationTime: modificationTime)
        try update(db)
    }
    
    /// Modifies the record according to the provided `modify` closure, and,
    /// if and only if the record was modified, sets `modificationTime` and
    /// executes an `UPDATE` statement that updates the modified columns.
    ///
    /// For example:
    ///
    /// ```swift
    /// try dbQueue.write { db in
    ///     var player = Player.find(db, id: 1)
    ///     let modified = try player.updateChangesWithTimestamp(db) {
    ///         $0.score = 1000
    ///     }
    ///     if modified {
    ///         print("player was modified")
    ///     } else {
    ///         print("player was not modified")
    ///     }
    /// }
    /// ```
    ///
    /// - parameters:
    ///     - db: A database connection.
    ///     - modificationTime: The modification date. If nil, the
    ///       transaction date is used.
    ///     - modify: A closure that modifies the record.
    /// - returns: Whether the record was changed and updated.
    @discardableResult
    mutating func updateChangesWithTimestamp(
        _ db: Database,
        modificationTime: Date? = nil,
        modify: (inout Self) -> Void)
    throws -> Bool
    {
        // Grab the changes performed by `modify`
        let initialChanges = try databaseChanges(modify: modify)
        if initialChanges.isEmpty {
            return false
        }
        
        // Update modification date and grab its column name
        let timestamp = try nextModificationTime(db, modificationTime: modificationTime)
        let dateChanges = try databaseChanges(modify: {
            $0.modificationTime = timestamp
        })
        
        // Update the modified columns
        let modifiedColumns = Set(initialChanges.keys).union(dateChanges.keys)
        try update(db, columns: modifiedColumns)
        return true
    }
    
    /// Sets `modificationTime`, and executes an `UPDATE` statement that
    /// updates the `modificationTime` column, if and only if the record
    /// was modified.
    ///
    /// - parameter modificationTime: The modification date. If nil, the
    ///   transaction date is used.
    mutating func touch(_ db: Database, modificationTime: Date? = nil) throws {
        let timestamp = try nextModificationTime(db, modificationTime: modificationTime)
        try updateChanges(db) {
            $0.modificationTime = timestamp
        }
    }

    func nextModificationTime(_ db: Database, modificationTime: Date?) throws -> Int64 {
        let timestamp = try modificationTime?.millisecondsSince1970 ?? db.transactionDate.millisecondsSince1970
        // Read-after-fetch: callers usually pass a record fetched outside the write
        // block, so a concurrent writer (e.g. CloudKit pull) may have bumped the row
        // since. Take the max of in-memory and on-disk to avoid letting the new write
        // regress past it — otherwise CloudKitOutboxEntry.enqueue's regression guard
        // will silently drop this update.
        let storedModificationTime = try persistedModificationTime(in: db)
        let currentModificationTime = max(self.modificationTime ?? 0, storedModificationTime ?? 0)
        guard currentModificationTime > 0 else { return timestamp }
        return max(timestamp, currentModificationTime + 1)
    }

    private func persistedModificationTime(in db: Database) throws -> Int64? {
        guard let id else { return nil }
        let row = try Row.fetchOne(
            db,
            sql: "SELECT modification_time FROM \"\(Self.databaseTableName)\" WHERE id = ?",
            arguments: [id]
        )
        return row?["modification_time"]
    }
}

extension Date {
    var millisecondsSince1970: Int64 {
        Int64(timeIntervalSince1970 * 1000.0)
    }
    
    init(millisecondsSince1970: Int64) {
        self.init(timeIntervalSince1970: Double(millisecondsSince1970) / 1000.0)
    }
}
