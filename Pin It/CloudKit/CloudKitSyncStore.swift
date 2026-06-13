//
//  CloudKitSyncStore.swift
//  Pin It
//
//  Created by OpenAI on 2026/5/4.
//

import Foundation
import GRDB

enum CloudKitAggregateType: String {
    case record
    case postGraph = "post_graph"
    case styleGraph = "style_graph"
    case setting
}

struct CloudKitRecordMetadata: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "cloudkit_record_metadata"

    var recordName: String
    var recordType: String
    var aggregateType: String
    var aggregateName: String
    var localVersion: Int64
    var lastSyncedVersion: Int64
    var serverChangeTag: String?
    var isDeleted: Bool
    var lastError: String?
    var updatedAt: Int64

    enum Columns {
        static let recordName = Column(CodingKeys.recordName)
    }

    enum CodingKeys: String, CodingKey {
        case recordName = "record_name"
        case recordType = "record_type"
        case aggregateType = "aggregate_type"
        case aggregateName = "aggregate_name"
        case localVersion = "local_version"
        case lastSyncedVersion = "last_synced_version"
        case serverChangeTag = "server_change_tag"
        case isDeleted = "is_deleted"
        case lastError = "last_error"
        case updatedAt = "updated_at"
    }
}

extension CloudKitRecordMetadata {
    static func markLocalChange(_ entry: CloudKitOutboxEntry, in db: Database) throws {
        let timestamp = try db.transactionDate.millisecondsSince1970
        let existing = try CloudKitRecordMetadata.fetchOne(db, key: entry.recordName)
        let localVersion = max(entry.localVersion, existing?.localVersion ?? 0)
        var metadata = CloudKitRecordMetadata(
            recordName: entry.recordName,
            recordType: entry.recordType,
            aggregateType: entry.aggregateType,
            aggregateName: entry.aggregateName,
            localVersion: localVersion,
            lastSyncedVersion: existing?.lastSyncedVersion ?? 0,
            serverChangeTag: existing?.serverChangeTag,
            isDeleted: entry.cloudKitOperation == .delete,
            lastError: nil,
            updatedAt: timestamp
        )
        try metadata.save(db)
    }

    static func markSynced(_ entries: [CloudKitOutboxEntry], in db: Database) throws {
        let timestamp = try db.transactionDate.millisecondsSince1970
        for entry in entries {
            guard var metadata = try CloudKitRecordMetadata.fetchOne(db, key: entry.recordName) else { continue }
            metadata.lastSyncedVersion = max(metadata.lastSyncedVersion, entry.localVersion)
            metadata.lastError = nil
            metadata.updatedAt = timestamp
            try metadata.save(db)
        }
    }

    static func markFailed(_ entries: [CloudKitOutboxEntry], error: Error, in db: Database) throws {
        let timestamp = try db.transactionDate.millisecondsSince1970
        for entry in entries {
            guard var metadata = try CloudKitRecordMetadata.fetchOne(db, key: entry.recordName) else { continue }
            if let entryId = entry.id,
               let failedEntry = try CloudKitOutboxEntry.fetchOne(db, id: entryId) {
                metadata.lastError = failedEntry.lastError ?? error.localizedDescription
            } else {
                metadata.lastError = error.localizedDescription
            }
            metadata.updatedAt = timestamp
            try metadata.save(db)
        }
    }

    static func markServerRecord(
        recordName: String,
        recordType: CloudKitRecordType,
        aggregateType: CloudKitAggregateType,
        aggregateName: String,
        serverChangeTag: String?,
        version: Int64,
        isDeleted: Bool,
        in db: Database
    ) throws {
        let timestamp = try db.transactionDate.millisecondsSince1970
        let existing = try CloudKitRecordMetadata.fetchOne(db, key: recordName)
        var metadata = CloudKitRecordMetadata(
            recordName: recordName,
            recordType: recordType.rawValue,
            aggregateType: aggregateType.rawValue,
            aggregateName: aggregateName,
            localVersion: existing?.localVersion ?? 0,
            lastSyncedVersion: max(existing?.lastSyncedVersion ?? 0, version),
            serverChangeTag: serverChangeTag,
            isDeleted: isDeleted,
            lastError: nil,
            updatedAt: timestamp
        )
        try metadata.save(db)
    }
}

struct CloudKitSettingRecord: Codable, FetchableRecord, MutablePersistableRecord, TableRecord {
    static let databaseTableName = "cloudkit_setting"
    static let defaultKey = "default"

    var key: String
    var defaultStyleSyncId: String?
    var defaultStyleModificationTime: Int64
    var pendingDefaultStyleSyncId: String?
    var pendingDefaultStyleModificationTime: Int64?
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case key
        case defaultStyleSyncId = "default_style_sync_id"
        case defaultStyleModificationTime = "default_style_modification_time"
        case pendingDefaultStyleSyncId = "pending_default_style_sync_id"
        case pendingDefaultStyleModificationTime = "pending_default_style_modification_time"
        case updatedAt = "updated_at"
    }
}

extension CloudKitSettingRecord {
    static func current(in db: Database) throws -> CloudKitSettingRecord {
        if let setting = try CloudKitSettingRecord.fetchOne(db, key: defaultKey) {
            return setting
        }
        return CloudKitSettingRecord(
            key: defaultKey,
            defaultStyleSyncId: nil,
            defaultStyleModificationTime: 0,
            pendingDefaultStyleSyncId: nil,
            pendingDefaultStyleModificationTime: nil,
            updatedAt: try db.transactionDate.millisecondsSince1970
        )
    }

    static func saveDefaultStyle(syncId: String?, modificationTime: Int64, in db: Database) throws {
        var setting = try current(in: db)
        setting.defaultStyleSyncId = syncId
        setting.defaultStyleModificationTime = modificationTime
        setting.pendingDefaultStyleSyncId = nil
        setting.pendingDefaultStyleModificationTime = nil
        setting.updatedAt = try db.transactionDate.millisecondsSince1970
        try setting.save(db)
    }

    static func storePendingDefaultStyle(syncId: String, modificationTime: Int64, in db: Database) throws -> Bool {
        var setting = try current(in: db)
        guard modificationTime > setting.defaultStyleModificationTime else {
            if setting.pendingDefaultStyleSyncId != nil || setting.pendingDefaultStyleModificationTime != nil {
                setting.pendingDefaultStyleSyncId = nil
                setting.pendingDefaultStyleModificationTime = nil
                setting.updatedAt = try db.transactionDate.millisecondsSince1970
                try setting.save(db)
                return true
            }
            return false
        }
        guard modificationTime > (setting.pendingDefaultStyleModificationTime ?? 0) else { return false }

        setting.pendingDefaultStyleSyncId = syncId
        setting.pendingDefaultStyleModificationTime = modificationTime
        setting.updatedAt = try db.transactionDate.millisecondsSince1970
        try setting.save(db)
        return true
    }

    static func clearPendingDefaultStyle(syncId: String? = nil, in db: Database) throws -> Bool {
        var setting = try current(in: db)
        if let syncId, setting.pendingDefaultStyleSyncId != syncId {
            return false
        }
        guard setting.pendingDefaultStyleSyncId != nil || setting.pendingDefaultStyleModificationTime != nil else {
            return false
        }
        setting.pendingDefaultStyleSyncId = nil
        setting.pendingDefaultStyleModificationTime = nil
        setting.updatedAt = try db.transactionDate.millisecondsSince1970
        try setting.save(db)
        return true
    }

    static func clearDefaultStyleSyncState(in db: Database) throws -> Bool {
        var setting = try current(in: db)
        let hadState = setting.defaultStyleSyncId != nil
        || setting.defaultStyleModificationTime != 0
        || setting.pendingDefaultStyleSyncId != nil
        || setting.pendingDefaultStyleModificationTime != nil
        guard hadState else { return false }

        setting.defaultStyleSyncId = nil
        setting.defaultStyleModificationTime = 0
        setting.pendingDefaultStyleSyncId = nil
        setting.pendingDefaultStyleModificationTime = nil
        setting.updatedAt = try db.transactionDate.millisecondsSince1970
        try setting.save(db)
        return true
    }
}
