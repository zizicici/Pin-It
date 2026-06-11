//
//  CloudKitRecordTypes.swift
//  Pin It
//
//  Created by OpenAI on 2026/5/3.
//

import CloudKit
import Foundation
import GRDB

enum CloudKitRecordType: String, CaseIterable {
    case post = "PinPost"
    case text = "PinText"
    case image = "PinImage"
    case style = "PinStyle"
    case decoration = "PinDecoration"
    case setting = "PinSetting"

    var recordNamePrefix: String {
        switch self {
        case .post:
            return "post"
        case .text:
            return "text"
        case .image:
            return "image"
        case .style:
            return "style"
        case .decoration:
            return "decoration"
        case .setting:
            return "setting"
        }
    }
}

enum CloudKitRecordName {
    static let zoneName = "PinItCloudKitSync"
    static let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    static let settingsName = "setting.default"
    /// Marker record stamped into the zone on every deliberate rebuild/clear.
    /// Lives outside CloudKitRecordType on purpose: it must never enter the
    /// outbox/apply pipeline, tombstones, or pruning.
    static let zoneMetaName = "zone.meta"
    static let zoneMetaRecordType = "PinZoneMeta"

    static func make(_ type: CloudKitRecordType, syncId: String) -> String {
        "\(type.recordNamePrefix).\(syncId)"
    }

    static func recordID(_ recordName: String) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: zoneID)
    }

    static func recordID(_ type: CloudKitRecordType, syncId: String) -> CKRecord.ID {
        recordID(make(type, syncId: syncId))
    }

    static func syncId(from recordName: String, type: CloudKitRecordType) -> String? {
        let prefix = "\(type.recordNamePrefix)."
        guard recordName.hasPrefix(prefix) else { return nil }
        return String(recordName.dropFirst(prefix.count))
    }
}

private protocol CloudKitPersistedRecord {
    var syncId: String { get }
    var modificationTime: Int64? { get }
    var cloudKitRecordName: String { get }
}

struct CloudKitOutboxEntry: Codable, FetchableRecord, MutablePersistableRecord, TableRecord, Identifiable {
    static let databaseTableName = "cloudkit_outbox"

    enum Operation: String, Codable {
        case save
        case delete
        case purge
    }

    var id: Int64?
    var recordType: String
    var recordName: String
    var operation: String
    var modificationTime: Int64
    var aggregateType: String
    var aggregateName: String
    var localVersion: Int64
    var createdAt: Int64
    var updatedAt: Int64
    var retryCount: Int
    var lastError: String?

    enum Columns {
        static let recordType = Column(CodingKeys.recordType)
        static let recordName = Column(CodingKeys.recordName)
        static let operation = Column(CodingKeys.operation)
        static let modificationTime = Column(CodingKeys.modificationTime)
        static let aggregateType = Column(CodingKeys.aggregateType)
        static let aggregateName = Column(CodingKeys.aggregateName)
        static let localVersion = Column(CodingKeys.localVersion)
        static let updatedAt = Column(CodingKeys.updatedAt)
        static let retryCount = Column(CodingKeys.retryCount)
        static let lastError = Column(CodingKeys.lastError)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case recordType = "record_type"
        case recordName = "record_name"
        case operation
        case modificationTime = "modification_time"
        case aggregateType = "aggregate_type"
        case aggregateName = "aggregate_name"
        case localVersion = "local_version"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case retryCount = "retry_count"
        case lastError = "last_error"
    }
}

extension CloudKitOutboxEntry {
    init(
        recordType: CloudKitRecordType,
        recordName: String,
        operation: Operation,
        modificationTime: Int64 = Date().nanoSecondSince1970,
        aggregateType: CloudKitAggregateType = .record,
        aggregateName: String? = nil,
        localVersion: Int64? = nil,
        timestamp: Int64 = Date().nanoSecondSince1970
    ) {
        self.recordType = recordType.rawValue
        self.recordName = recordName
        self.operation = operation.rawValue
        self.modificationTime = modificationTime
        self.aggregateType = aggregateType.rawValue
        self.aggregateName = aggregateName ?? recordName
        self.localVersion = localVersion ?? modificationTime
        self.createdAt = timestamp
        self.updatedAt = timestamp
        self.retryCount = 0
        self.lastError = nil
    }

    var cloudKitRecordType: CloudKitRecordType? {
        CloudKitRecordType(rawValue: recordType)
    }

    var cloudKitOperation: Operation? {
        Operation(rawValue: operation)
    }

    static func enqueue(_ entry: CloudKitOutboxEntry, in db: Database) throws {
        var entry = entry
        if let existing = try CloudKitOutboxEntry
            .filter(Columns.recordName == entry.recordName)
            .fetchOne(db) {
            // Don't regress timestamps within the same operation. A late save with an
            // older mod time shouldn't overwrite a newer same-op intent. But operation
            // transitions (save->delete, delete->save, save/delete->purge) always go
            // through — the new operation reflects the latest user intent regardless
            // of the timestamp ordering, since the record-level deletionTime/version
            // semantics don't compare across op types.
            if existing.operation == entry.operation,
               entry.modificationTime < existing.modificationTime {
                return
            }
            entry.id = existing.id
            entry.createdAt = existing.createdAt
            if existing.operation == entry.operation && existing.localVersion == entry.localVersion {
                entry.retryCount = existing.retryCount
                entry.lastError = existing.lastError
            }
        }
        if entry.aggregateName.isEmpty {
            entry.aggregateName = entry.recordName
        }
        if entry.localVersion == 0 {
            entry.localVersion = entry.modificationTime
        }
        try entry.save(db)
        if entry.cloudKitOperation != .purge {
            try CloudKitRecordMetadata.markLocalChange(entry, in: db)
        }
        if entry.cloudKitOperation == .save {
            try CloudKitLocalTombstone.deleteOne(db, key: entry.recordName)
        }
        if entry.cloudKitOperation == .delete,
           let recordType = entry.cloudKitRecordType {
            try CloudKitLocalTombstone.store(
                recordType: recordType,
                recordName: entry.recordName,
                deletionTime: entry.modificationTime,
                aggregateType: CloudKitAggregateType(rawValue: entry.aggregateType),
                aggregateName: entry.aggregateName == entry.recordName ? nil : entry.aggregateName,
                in: db
            )
        }
    }

    static func enqueueSave(
        recordType: CloudKitRecordType,
        syncId: String,
        modificationTime: Int64?,
        aggregateType: CloudKitAggregateType = .record,
        aggregateName: String? = nil,
        localVersion: Int64? = nil,
        in db: Database
    ) throws {
        try enqueue(
            CloudKitOutboxEntry(
                recordType: recordType,
                recordName: CloudKitRecordName.make(recordType, syncId: syncId),
                operation: .save,
                modificationTime: modificationTime ?? db.transactionDate.nanoSecondSince1970,
                aggregateType: aggregateType,
                aggregateName: aggregateName,
                localVersion: localVersion,
                timestamp: db.transactionDate.nanoSecondSince1970
            ),
            in: db
        )
    }

    static func enqueueDelete(
        recordType: CloudKitRecordType,
        syncId: String,
        deletionTime: Int64? = nil,
        aggregateType: CloudKitAggregateType = .record,
        aggregateName: String? = nil,
        in db: Database
    ) throws {
        try enqueueDelete(
            recordType: recordType,
            recordName: CloudKitRecordName.make(recordType, syncId: syncId),
            deletionTime: deletionTime,
            aggregateType: aggregateType,
            aggregateName: aggregateName,
            in: db
        )
    }

    /// `aggregateType`/`aggregateName` mark a delete as part of a post/style
    /// cascade (the parent's record name). Cascade members are arbitrated as
    /// ONE graph-level intent on both the apply and the send path — a lone
    /// child delete keeps the default per-record `.record` semantics.
    static func enqueueDelete(
        recordType: CloudKitRecordType,
        recordName: String,
        deletionTime: Int64? = nil,
        aggregateType: CloudKitAggregateType = .record,
        aggregateName: String? = nil,
        in db: Database
    ) throws {
        try enqueue(
            CloudKitOutboxEntry(
                recordType: recordType,
                recordName: recordName,
                operation: .delete,
                modificationTime: deletionTime ?? db.transactionDate.nanoSecondSince1970,
                aggregateType: aggregateType,
                aggregateName: aggregateName ?? recordName,
                localVersion: deletionTime ?? db.transactionDate.nanoSecondSince1970,
                timestamp: db.transactionDate.nanoSecondSince1970
            ),
            in: db
        )
    }

    static func enqueueSetting(modificationTime: Int64, in db: Database) throws {
        try enqueue(
            CloudKitOutboxEntry(
                recordType: .setting,
                recordName: CloudKitRecordName.settingsName,
                operation: .save,
                modificationTime: modificationTime,
                aggregateType: .setting,
                aggregateName: CloudKitRecordName.settingsName,
                localVersion: modificationTime,
                timestamp: db.transactionDate.nanoSecondSince1970
            ),
            in: db
        )
    }

    static func enqueuePurge(recordType: CloudKitRecordType, recordName: String, in db: Database) throws {
        let timestamp = try db.transactionDate.nanoSecondSince1970
        try enqueue(
            CloudKitOutboxEntry(
                recordType: recordType,
                recordName: recordName,
                operation: .purge,
                modificationTime: timestamp,
                aggregateType: .record,
                aggregateName: recordName,
                localVersion: timestamp,
                timestamp: timestamp
            ),
            in: db
        )
    }

    static func clear(ids: [Int64], in db: Database) throws {
        guard !ids.isEmpty else { return }
        let entries = try CloudKitOutboxEntry.filter(ids: ids).fetchAll(db)
        let purgeEntries = entries.filter { $0.cloudKitOperation == .purge }
        let syncedEntries = entries.filter { $0.cloudKitOperation != .purge }
        try CloudKitRecordMetadata.markSynced(syncedEntries, in: db)
        for entry in purgeEntries {
            try CloudKitRecordMetadata.deleteOne(db, key: entry.recordName)
            // The purge closes the record's lifecycle; without this the local
            // tombstone row would outlive the remote tombstone forever.
            try CloudKitLocalTombstone.deleteOne(db, key: entry.recordName)
        }
        try CloudKitOutboxEntry.deleteAll(db, ids: ids)
    }

    static func drop(ids: [Int64], in db: Database) throws {
        guard !ids.isEmpty else { return }
        try CloudKitOutboxEntry.deleteAll(db, ids: ids)
    }

    /// Clear/drop gated on the row still carrying the snapshot's
    /// operation + localVersion. `enqueue` upserts by record name and reuses
    /// the row id, so between a caller's snapshot and its write the same id
    /// can come to hold a NEWER intent (e.g. the save it batched became the
    /// user's delete during the server round trip) — removing by id alone
    /// would discard that intent with nothing left to re-enqueue it.
    static func clear(matching entries: [CloudKitOutboxEntry], in db: Database) throws {
        try clear(ids: stillMatching(entries, in: db).compactMap(\.id), in: db)
    }

    static func drop(matching entries: [CloudKitOutboxEntry], in db: Database) throws {
        try drop(ids: stillMatching(entries, in: db).compactMap(\.id), in: db)
    }

    private static func stillMatching(_ entries: [CloudKitOutboxEntry], in db: Database) throws -> [CloudKitOutboxEntry] {
        var matching: [CloudKitOutboxEntry] = []
        for entry in entries {
            guard let id = entry.id,
                  let current = try CloudKitOutboxEntry.fetchOne(db, id: id),
                  current.operation == entry.operation,
                  current.localVersion == entry.localVersion else { continue }
            matching.append(current)
        }
        return matching
    }

    static func clear(recordName: String, in db: Database) throws {
        _ = try CloudKitOutboxEntry
            .filter(Columns.recordName == recordName)
            .deleteAll(db)
    }

    static func clear(recordName: String, modifiedBefore modificationTime: Int64, in db: Database) throws {
        _ = try CloudKitOutboxEntry
            .filter(Columns.recordName == recordName && Columns.modificationTime <= modificationTime)
            .deleteAll(db)
    }

    static func markFailed(ids: [Int64], error: Error, in db: Database) throws {
        guard !ids.isEmpty else { return }
        let message = detailedErrorDescription(error)
        let timestamp = try db.transactionDate.nanoSecondSince1970
        var failedEntries: [CloudKitOutboxEntry] = []
        for id in ids {
            guard var entry = try CloudKitOutboxEntry.fetchOne(db, id: id) else { continue }
            entry.retryCount += 1
            entry.lastError = message
            entry.updatedAt = timestamp
            try entry.update(db)
            failedEntries.append(entry)
        }
        try CloudKitRecordMetadata.markFailed(failedEntries, error: error, in: db)
    }

    static func markFailed(matching entries: [CloudKitOutboxEntry], error: Error, in db: Database) throws {
        try markFailed(ids: stillMatching(entries, in: db).compactMap(\.id), error: error, in: db)
    }

    static func hasEntries(excludingMatching entries: [CloudKitOutboxEntry], in db: Database) throws -> Bool {
        let excludedIDs = Set(try stillMatching(entries, in: db).compactMap(\.id))
        for entry in try CloudKitOutboxEntry.fetchAll(db) {
            guard let id = entry.id else { return true }
            if !excludedIDs.contains(id) {
                return true
            }
        }
        return false
    }

    private static func detailedErrorDescription(_ error: Error) -> String {
        guard let cloudKitError = error as? CKError else {
            return error.localizedDescription
        }

        var parts = ["CKError.\(cloudKitError.code)"]
        if let retryAfter = cloudKitError.userInfo[CKErrorRetryAfterKey] as? TimeInterval {
            parts.append("retryAfter=\(retryAfter)")
        }
        if let partialErrors = cloudKitError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error],
           !partialErrors.isEmpty {
            let details = partialErrors
                .prefix(5)
                .map { key, value in "\(key): \(value.localizedDescription)" }
                .joined(separator: "; ")
            parts.append("partial=\(details)")
        }
        parts.append(cloudKitError.localizedDescription)
        return parts.joined(separator: " | ")
    }

    static func failedCount(in db: Database) throws -> Int {
        try CloudKitOutboxEntry
            .filter(Columns.lastError != nil)
            .fetchCount(db)
    }

    static func failedEntries(limit: Int, in db: Database) throws -> [CloudKitOutboxEntry] {
        try CloudKitOutboxEntry
            .filter(Columns.lastError != nil)
            .order(Columns.updatedAt.desc)
            .limit(limit)
            .fetchAll(db)
    }

    static func enqueueBootstrapSaves(in db: Database) throws {
        try enqueueBootstrapSaves(recordType: .post, records: Post.fetchAll(db), in: db)
        try enqueueBootstrapSaves(recordType: .text, records: PostText.fetchAll(db), in: db)
        try enqueueBootstrapSaves(recordType: .image, records: PostImage.fetchAll(db), in: db)
        try enqueueBootstrapSaves(recordType: .style, records: PostStyle.fetchAll(db), in: db)
        try enqueueBootstrapSaves(recordType: .decoration, records: PostDecoration.fetchAll(db), in: db)
    }

    /// Enqueue saves and deletes for records that diverged from CloudKit while sync
    /// was disabled. Compared with bootstrap, this only queues genuinely-changed
    /// records — by metadata.lastSyncedVersion for edits, and by metadata-rows-with-
    /// no-local-row for offline deletes. Called when re-enabling sync on a device
    /// that already had CloudKit metadata (not a true first-time setup).
    /// The save half of offline reconciliation, standalone: enqueue records whose
    /// local modification time advanced past the last synced version. The
    /// zone-discontinuity probe runs this before pruning so divergent local edits
    /// gain outbox protection and re-upload afterwards.
    static func enqueueDivergentSaves(in db: Database) throws {
        let metadataRows = try CloudKitRecordMetadata.fetchAll(db)
        let metadataByName = Dictionary(uniqueKeysWithValues: metadataRows.map { ($0.recordName, $0) })
        var seenRecordNames = Set<String>()
        try enqueueDivergentSaves(recordType: .post, records: Post.fetchAll(db), metadataByName: metadataByName, seen: &seenRecordNames, in: db)
        try enqueueDivergentSaves(recordType: .text, records: PostText.fetchAll(db), metadataByName: metadataByName, seen: &seenRecordNames, in: db)
        try enqueueDivergentSaves(recordType: .image, records: PostImage.fetchAll(db), metadataByName: metadataByName, seen: &seenRecordNames, in: db)
        try enqueueDivergentSaves(recordType: .style, records: PostStyle.fetchAll(db), metadataByName: metadataByName, seen: &seenRecordNames, in: db)
        try enqueueDivergentSaves(recordType: .decoration, records: PostDecoration.fetchAll(db), metadataByName: metadataByName, seen: &seenRecordNames, in: db)
    }

    static func enqueueOfflineReconciliation(in db: Database) throws {
        let metadataRows = try CloudKitRecordMetadata.fetchAll(db)
        let metadataByName = Dictionary(uniqueKeysWithValues: metadataRows.map { ($0.recordName, $0) })
        let tombstonesByRecordName = try CloudKitLocalTombstone.allByRecordName(in: db)
        var seenRecordNames = Set<String>()

        try enqueueDivergentSaves(recordType: .post, records: Post.fetchAll(db), metadataByName: metadataByName, seen: &seenRecordNames, in: db)
        try enqueueDivergentSaves(recordType: .text, records: PostText.fetchAll(db), metadataByName: metadataByName, seen: &seenRecordNames, in: db)
        try enqueueDivergentSaves(recordType: .image, records: PostImage.fetchAll(db), metadataByName: metadataByName, seen: &seenRecordNames, in: db)
        try enqueueDivergentSaves(recordType: .style, records: PostStyle.fetchAll(db), metadataByName: metadataByName, seen: &seenRecordNames, in: db)
        try enqueueDivergentSaves(recordType: .decoration, records: PostDecoration.fetchAll(db), metadataByName: metadataByName, seen: &seenRecordNames, in: db)

        for metadata in metadataRows {
            guard !metadata.isDeleted,
                  !seenRecordNames.contains(metadata.recordName),
                  let recordType = CloudKitRecordType(rawValue: metadata.recordType),
                  recordType != .setting else { continue }
            // Prefer the real tombstone written at delete time (offline deletes
            // store one when remoteDataMayExist). Fall back to lastSyncedVersion+1
            // — conservative: server-equal-or-newer wins via serverStateWins, so a
            // remote edit made after our last sync isn't tombstoned.
            let tombstone = tombstonesByRecordName[metadata.recordName]
            let deletionTime = tombstone?.deletionTime ?? (metadata.lastSyncedVersion + 1)
            try CloudKitOutboxEntry.enqueueDelete(
                recordType: recordType,
                recordName: metadata.recordName,
                deletionTime: deletionTime,
                aggregateType: tombstone?.cascadeAggregateType ?? .record,
                aggregateName: tombstone?.aggregateName,
                in: db
            )
        }
    }

    private static func enqueueDivergentSaves<Record: CloudKitPersistedRecord>(
        recordType: CloudKitRecordType,
        records: [Record],
        metadataByName: [String: CloudKitRecordMetadata],
        seen: inout Set<String>,
        in db: Database
    ) throws {
        for record in records {
            seen.insert(record.cloudKitRecordName)
            guard try !OnboardingLocalRecord.isMarked(recordType: recordType, syncId: record.syncId, in: db) else { continue }
            let lastSynced = metadataByName[record.cloudKitRecordName]?.lastSyncedVersion ?? -1
            guard (record.modificationTime ?? 0) > lastSynced else { continue }
            try enqueueSave(recordType: recordType, syncId: record.syncId, modificationTime: record.modificationTime, in: db)
        }
    }

    static func enqueuePostGraphSave(postId: Int64, modificationTime: Int64?, in db: Database) throws {
        guard let post = try Post.fetchOne(db, id: postId) else { return }
        let transactionTime = try db.transactionDate.nanoSecondSince1970
        let requestedVersion = modificationTime ?? transactionTime
        let graphVersion = max(requestedVersion, (post.modificationTime ?? 0) + 1)
        let aggregateName = post.cloudKitRecordName

        try Post
            .filter(Column(Post.CodingKeys.id) == postId)
            .updateAll(db, Column(Post.CodingKeys.modificationTime).set(to: graphVersion))
        try enqueuePostGraphRecord(recordType: .post, syncId: post.syncId, aggregateName: aggregateName, graphVersion: graphVersion, in: db)
    }

    static func enqueueStyleGraphSave(styleId: Int64, modificationTime: Int64?, in db: Database) throws {
        guard let style = try PostStyle.fetchOne(db, id: styleId) else { return }
        let requestedVersion: Int64
        if let modificationTime {
            requestedVersion = modificationTime
        } else {
            requestedVersion = try db.transactionDate.nanoSecondSince1970
        }
        let graphVersion = max(requestedVersion, (style.modificationTime ?? 0) + 1)
        let aggregateName = style.cloudKitRecordName
        try PostStyle
            .filter(Column(PostStyle.CodingKeys.id) == styleId)
            .updateAll(db, Column(PostStyle.CodingKeys.modificationTime).set(to: graphVersion))
        try enqueueSave(
            recordType: .style,
            syncId: style.syncId,
            modificationTime: graphVersion,
            aggregateType: .styleGraph,
            aggregateName: aggregateName,
            localVersion: graphVersion,
            in: db
        )
    }

    private static func enqueueBootstrapSaves<Record: CloudKitPersistedRecord>(
        recordType: CloudKitRecordType,
        records: [Record],
        in db: Database
    ) throws {
        for record in records where try !OnboardingLocalRecord.isMarked(recordType: recordType, syncId: record.syncId, in: db) {
            try enqueueSave(recordType: recordType, syncId: record.syncId, modificationTime: record.modificationTime, in: db)
        }
    }

    private static func enqueuePostGraphRecord(
        recordType: CloudKitRecordType,
        syncId: String,
        aggregateName: String,
        graphVersion: Int64,
        in db: Database
    ) throws {
        guard try !OnboardingLocalRecord.isMarked(recordType: recordType, syncId: syncId, in: db) else {
            try clear(recordName: CloudKitRecordName.make(recordType, syncId: syncId), in: db)
            return
        }
        try enqueueSave(
            recordType: recordType,
            syncId: syncId,
            modificationTime: graphVersion,
            aggregateType: .postGraph,
            aggregateName: aggregateName,
            localVersion: graphVersion,
            in: db
        )
    }

}

/// Why zone continuity was lost — decides the keep-vs-prune default for a
/// marker-less but populated zone in the discontinuity probe.
enum ZoneDiscontinuityCause: Int {
    /// zoneNotFound / a zone-deletion event: the zone may have been recreated
    /// (and repopulated by a peer) since this device last saw it.
    case zoneLost = 1
    /// The change token expired against a zone whose identity is intact.
    case tokenExpired = 2
}

struct CloudKitSyncState: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "cloudkit_sync_state"

    var key: String
    var value: Data?

    enum Key {
        static let syncEngineState = "sync_engine_state"
        static let suppressNextBootstrap = "suppress_next_bootstrap"
        static let preserveLocalOnNextFullFetch = "preserve_local_on_next_full_fetch"
        static let zoneGeneration = "zone_generation"
        static let pendingZoneDiscontinuityProbe = "pending_zone_discontinuity_probe"
        static let accountUserRecordName = "account_user_record_name"
        static let pendingFullFetchRecovery = "pending_full_fetch_recovery"
    }

    enum Columns {
        static let key = Column(CodingKeys.key)
        static let value = Column(CodingKeys.value)
    }

    enum CodingKeys: String, CodingKey {
        case key
        case value
    }
}

struct CloudKitLocalTombstone: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "cloudkit_tombstone"

    var recordName: String
    var deletedRecordType: String
    var deletionTime: Int64
    var updatedAt: Int64
    /// Set when this delete is part of a post/style cascade: the aggregate
    /// type and the PARENT's record name. Nil for individual deletes.
    var aggregateType: String?
    var aggregateName: String?

    enum Columns {
        static let recordName = Column(CodingKeys.recordName)
        static let deletionTime = Column(CodingKeys.deletionTime)
    }

    enum CodingKeys: String, CodingKey {
        case recordName = "record_name"
        case deletedRecordType = "deleted_record_type"
        case deletionTime = "deletion_time"
        case updatedAt = "updated_at"
        case aggregateType = "aggregate_type"
        case aggregateName = "aggregate_name"
    }
}

extension CloudKitLocalTombstone {
    init(
        recordType: CloudKitRecordType,
        recordName: String,
        deletionTime: Int64,
        updatedAt: Int64,
        aggregateType: CloudKitAggregateType? = nil,
        aggregateName: String? = nil
    ) {
        self.recordName = recordName
        self.deletedRecordType = recordType.rawValue
        self.deletionTime = deletionTime
        self.updatedAt = updatedAt
        self.aggregateType = aggregateType.flatMap { $0 == .record || $0 == .setting ? nil : $0.rawValue }
        self.aggregateName = self.aggregateType == nil ? nil : aggregateName
    }

    var cloudKitRecordType: CloudKitRecordType? {
        CloudKitRecordType(rawValue: deletedRecordType)
    }

    var cascadeAggregateType: CloudKitAggregateType? {
        aggregateType.flatMap(CloudKitAggregateType.init(rawValue:))
    }

    static func store(
        recordType: CloudKitRecordType,
        recordName: String,
        deletionTime: Int64,
        aggregateType: CloudKitAggregateType? = nil,
        aggregateName: String? = nil,
        in db: Database
    ) throws {
        if let existing = try CloudKitLocalTombstone.fetchOne(db, key: recordName),
           existing.deletionTime >= deletionTime {
            return
        }

        var tombstone = CloudKitLocalTombstone(
            recordType: recordType,
            recordName: recordName,
            deletionTime: deletionTime,
            updatedAt: try db.transactionDate.nanoSecondSince1970,
            aggregateType: aggregateType,
            aggregateName: aggregateName
        )
        try tombstone.save(db)
    }

    static func allByRecordName(in db: Database) throws -> [String: CloudKitLocalTombstone] {
        let tombstones = try CloudKitLocalTombstone.fetchAll(db)
        return Dictionary(uniqueKeysWithValues: tombstones.map { ($0.recordName, $0) })
    }
}

struct CloudKitSyncStateDecodingError: Error {
    var underlying: Error
}

extension CloudKitSyncState {
    static func syncEngineStateSerialization(in db: Database) throws -> CKSyncEngine.State.Serialization? {
        guard let state = try CloudKitSyncState.fetchOne(db, key: Key.syncEngineState),
              let data = state.value else {
            return nil
        }
        do {
            return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        } catch {
            // Distinguished from DB errors so the caller can self-heal:
            // a corrupt/undecodable stored state would otherwise fail every
            // engine construction forever, permanently wedging sync.
            throw CloudKitSyncStateDecodingError(underlying: error)
        }
    }

    static func setSyncEngineStateSerialization(_ serialization: CKSyncEngine.State.Serialization?, in db: Database) throws {
        guard let serialization else {
            try clearSyncEngineStateSerialization(in: db)
            return
        }
        let data = try JSONEncoder().encode(serialization)
        var state = CloudKitSyncState(key: Key.syncEngineState, value: data)
        try state.save(db)
    }

    static func clearSyncEngineStateSerialization(in db: Database) throws {
        _ = try CloudKitSyncState
            .filter(Columns.key == Key.syncEngineState)
            .deleteAll(db)
    }

    static func suppressBootstrapForNextFreshEngine(in db: Database) throws {
        try setIntegerValue(1, forKey: Key.suppressNextBootstrap, in: db)
    }

    static func clearBootstrapSuppression(in db: Database) throws {
        try deleteValue(forKey: Key.suppressNextBootstrap, in: db)
    }

    static func consumeBootstrapSuppression(in db: Database) throws -> Bool {
        let isSuppressed = (try integerValue(forKey: Key.suppressNextBootstrap, in: db) ?? 0) != 0
        if isSuppressed {
            try clearBootstrapSuppression(in: db)
        }
        return isSuppressed
    }

    /// Last reset-marker generation observed in (or written to) the zone. Used
    /// to tell a peer's deliberate rebuild apart from accidental zone loss.
    static func zoneGeneration(in db: Database) throws -> String? {
        guard let state = try CloudKitSyncState.fetchOne(db, key: Key.zoneGeneration),
              let data = state.value else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func setZoneGeneration(_ generation: String, in db: Database) throws {
        var state = CloudKitSyncState(key: Key.zoneGeneration, value: generation.data(using: .utf8))
        try state.save(db)
    }

    static func clearZoneGeneration(in db: Database) throws {
        try deleteValue(forKey: Key.zoneGeneration, in: db)
    }

    /// The CloudKit user identity (the container user record's name) the local
    /// sync bookkeeping belongs to. Deliberately survives the disable cleanup:
    /// it is the only way to detect an iCloud account switch that happened
    /// while sync was off, where no stored engine state remains for a fresh
    /// CKSyncEngine to surface `.switchAccounts` from.
    static func accountUserRecordName(in db: Database) throws -> String? {
        guard let state = try CloudKitSyncState.fetchOne(db, key: Key.accountUserRecordName),
              let data = state.value else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func setAccountUserRecordName(_ recordName: String, in db: Database) throws {
        var state = CloudKitSyncState(key: Key.accountUserRecordName, value: recordName.data(using: .utf8))
        try state.save(db)
    }

    static func clearAccountUserRecordName(in db: Database) throws {
        try deleteValue(forKey: Key.accountUserRecordName, in: db)
    }

    /// Set when the zone disappeared (deleted by a peer, zoneNotFound, expired
    /// change token). The next full fetch decides keep-vs-prune by comparing the
    /// fetched reset marker against the stored zone generation, and clears this
    /// flag atomically inside the apply transaction. The stored value records
    /// WHY continuity was lost — a marker-less but populated zone is only safe
    /// to prune against when the cause proves zone identity was kept
    /// (`tokenExpired`); after a `zoneLost` the zone may have been recreated
    /// and repopulated by a single peer, so absent records must merge, not die.
    static func markZoneDiscontinuityProbe(cause: ZoneDiscontinuityCause, in db: Database) throws {
        // A zoneLost probe must not be downgraded by a later tokenExpired
        // arming (the recreated zone invalidates old tokens, so both arrive).
        if let existing = try zoneDiscontinuityProbeCause(in: db), existing == .zoneLost {
            return
        }
        try setIntegerValue(Int64(cause.rawValue), forKey: Key.pendingZoneDiscontinuityProbe, in: db)
    }

    static func clearZoneDiscontinuityProbe(in db: Database) throws {
        try deleteValue(forKey: Key.pendingZoneDiscontinuityProbe, in: db)
    }

    static func isZoneDiscontinuityProbePending(in db: Database) throws -> Bool {
        (try integerValue(forKey: Key.pendingZoneDiscontinuityProbe, in: db) ?? 0) != 0
    }

    static func zoneDiscontinuityProbeCause(in db: Database) throws -> ZoneDiscontinuityCause? {
        guard let value = try integerValue(forKey: Key.pendingZoneDiscontinuityProbe, in: db), value != 0 else {
            return nil
        }
        // Legacy probes stored 1, which maps to zoneLost — the conservative
        // (keep + merge) branch.
        return ZoneDiscontinuityCause(rawValue: Int(value)) ?? .zoneLost
    }

    /// Set when a losing cascade delete was aborted mid-send: its outbox
    /// entries, local tombstones and metadata were dropped, and the surviving
    /// family must be restored from the server by a full re-fetch. Durable so
    /// a crash between the abort transaction and the re-fetch can't lose the
    /// restore intent; consumed inside the engine-state reset that starts the
    /// re-fetch.
    static func markPendingFullFetchRecovery(in db: Database) throws {
        try setIntegerValue(1, forKey: Key.pendingFullFetchRecovery, in: db)
    }

    static func clearPendingFullFetchRecovery(in db: Database) throws {
        try deleteValue(forKey: Key.pendingFullFetchRecovery, in: db)
    }

    static func isPendingFullFetchRecovery(in db: Database) throws -> Bool {
        (try integerValue(forKey: Key.pendingFullFetchRecovery, in: db) ?? 0) != 0
    }

    static func preserveLocalRecordsForNextFullFetch(in db: Database) throws {
        try setIntegerValue(1, forKey: Key.preserveLocalOnNextFullFetch, in: db)
    }

    static func clearLocalRecordPreservation(in db: Database) throws {
        try deleteValue(forKey: Key.preserveLocalOnNextFullFetch, in: db)
    }

    static func consumeLocalRecordPreservation(in db: Database) throws -> Bool {
        let shouldPreserve = (try integerValue(forKey: Key.preserveLocalOnNextFullFetch, in: db) ?? 0) != 0
        if shouldPreserve {
            try clearLocalRecordPreservation(in: db)
        }
        return shouldPreserve
    }

    private static func integerValue(forKey key: String, in db: Database) throws -> Int64? {
        guard let state = try CloudKitSyncState.fetchOne(db, key: key),
              let data = state.value,
              let stringValue = String(data: data, encoding: .utf8) else {
            return nil
        }
        return Int64(stringValue)
    }

    private static func setIntegerValue(_ value: Int64, forKey key: String, in db: Database) throws {
        let data = String(value).data(using: .utf8)
        var state = CloudKitSyncState(key: key, value: data)
        try state.save(db)
    }

    private static func deleteValue(forKey key: String, in db: Database) throws {
        _ = try CloudKitSyncState
            .filter(Columns.key == key)
            .deleteAll(db)
    }
}

extension Post: CloudKitPersistedRecord {
    var cloudKitRecordName: String {
        CloudKitRecordName.make(.post, syncId: syncId)
    }
}

extension PostText: CloudKitPersistedRecord {
    var cloudKitRecordName: String {
        CloudKitRecordName.make(.text, syncId: syncId)
    }
}

extension PostImage: CloudKitPersistedRecord {
    var cloudKitRecordName: String {
        CloudKitRecordName.make(.image, syncId: syncId)
    }
}

extension PostStyle: CloudKitPersistedRecord {
    var cloudKitRecordName: String {
        CloudKitRecordName.make(.style, syncId: syncId)
    }
}

extension PostDecoration: CloudKitPersistedRecord {
    var cloudKitRecordName: String {
        CloudKitRecordName.make(.decoration, syncId: syncId)
    }
}
