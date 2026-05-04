//
//  CloudKitRecordSyncManager+RecordHelpers.swift
//  Pin It
//

import CloudKit
import Foundation
import GRDB

extension CloudKitRecordSyncManager {
    func imageRecordNamesToStage(_ changes: RemoteChangeSet) throws -> Set<String> {
        var recordNames = Set<String>()
        try AppDatabase.shared.dbWriter?.read { db in
            let pendingDeletes = try pendingDeleteOutboxByRecordName(in: db)
            let localTombstones = try CloudKitLocalTombstone.allByRecordName(in: db)
            for record in activeRemoteRecords(
                type: .image,
                changes: changes,
                pendingDeletes: pendingDeletes,
                localTombstones: localTombstones
            ) {
                guard let syncId = stringValue(Field.syncId, in: record) else {
                    recordNames.insert(record.recordID.recordName)
                    continue
                }
                let existing = try PostImage
                    .filter(Column(PostImage.CodingKeys.syncId) == syncId)
                    .fetchOne(db)
                guard let existing else {
                    recordNames.insert(record.recordID.recordName)
                    continue
                }
                let remoteOriginalFileName = stringValue(Field.originalFileName, in: record)
                let remoteProcessedFileName = stringValue(Field.processedFileName, in: record)
                let remoteModificationTime = modificationTime(of: record)
                let needsOriginalAsset = (remoteOriginalFileName != nil && remoteOriginalFileName != existing.original)
                || ImageCacheManager.shared.getURL(name: existing.original, type: .original) == nil
                let needsProcessedAsset = (remoteProcessedFileName != nil && remoteProcessedFileName != existing.processed)
                || ImageCacheManager.shared.getURL(name: existing.processed, type: .processed) == nil
                if remoteModificationTime > (existing.modificationTime ?? 0) || needsOriginalAsset || needsProcessedAsset {
                    recordNames.insert(record.recordID.recordName)
                }
            }
        }
        return recordNames
    }

    func isDeletedRecord(_ record: CKRecord) -> Bool {
        boolValue(Field.isDeleted, in: record) == true
    }

    func makeRemoteTombstone(from record: CKRecord, type: CloudKitRecordType) -> RemoteTombstone? {
        let deletedRecordName = stringValue(Field.deletedRecordName, in: record) ?? record.recordID.recordName
        let deletedRecordType = stringValue(Field.deletedRecordType, in: record)
            .flatMap(CloudKitRecordType.init(rawValue:))
            ?? type
        return RemoteTombstone(
            deletedRecordType: deletedRecordType,
            deletedRecordName: deletedRecordName,
            deletionTime: int64Value(Field.deletionTime, in: record) ?? modificationTime(of: record)
        )
    }

    func modificationTime(of record: CKRecord) -> Int64 {
        int64Value(Field.modificationTime, in: record)
        ?? record.modificationDate?.nanoSecondSince1970
        ?? 0
    }

    func stageImageAssets(_ changes: RemoteChangeSet, allowedRecordNames: Set<String>) throws -> [String: StagedImageAssets] {
        var stagedAssetsByRecordName: [String: StagedImageAssets] = [:]
        var copiedFiles: [(String, CacheImageType)] = []
        do {
            for record in changes.activeRecordsByType[.image] ?? [] {
                guard allowedRecordNames.contains(record.recordID.recordName) else { continue }
                let syncId = stringValue(Field.syncId, in: record) ?? record.recordID.recordName
                let originalName = try copyAsset(
                    field: Field.originalAsset,
                    from: record,
                    preferredFileName: stringValue(Field.originalFileName, in: record) ?? "\(syncId)-original",
                    type: .original
                )
                if let originalName {
                    copiedFiles.append((originalName, .original))
                }
                let processedName = try copyAsset(
                    field: Field.processedAsset,
                    from: record,
                    preferredFileName: stringValue(Field.processedFileName, in: record) ?? "\(syncId)-processed",
                    type: .processed
                )
                if let processedName {
                    copiedFiles.append((processedName, .processed))
                }
                if originalName != nil || processedName != nil {
                    stagedAssetsByRecordName[record.recordID.recordName] = StagedImageAssets(
                        originalName: originalName,
                        processedName: processedName
                    )
                }
            }
        } catch {
            cleanupCopiedImageFiles(copiedFiles)
            throw error
        }
        return stagedAssetsByRecordName
    }

    func copyAsset(
        field: String,
        from record: CKRecord,
        preferredFileName: String,
        type: CacheImageType
    ) throws -> String? {
        guard let asset = record[field] as? CKAsset,
              let fileURL = asset.fileURL else {
            return nil
        }
        return try ImageCacheManager.shared.copyImage(from: fileURL, preferredFileName: preferredFileName, type: type, overwrite: false)
    }

    func stringValue(_ field: String, in record: CKRecord) -> String? {
        record[field] as? String
    }

    func intValue(_ field: String, in record: CKRecord) -> Int? {
        (record[field] as? NSNumber)?.intValue
    }

    func int64Value(_ field: String, in record: CKRecord) -> Int64? {
        (record[field] as? NSNumber)?.int64Value
    }

    func boolValue(_ field: String, in record: CKRecord) -> Bool? {
        (record[field] as? NSNumber)?.boolValue
    }

    func set(_ value: String?, for field: String, on record: CKRecord) {
        record[field] = value as CKRecordValue?
    }

    func set(_ value: Int64?, for field: String, on record: CKRecord) {
        if let value {
            record[field] = NSNumber(value: value)
        } else {
            record[field] = nil
        }
    }

    func set(_ value: Bool, for field: String, on record: CKRecord) {
        record[field] = NSNumber(value: value)
    }
}
