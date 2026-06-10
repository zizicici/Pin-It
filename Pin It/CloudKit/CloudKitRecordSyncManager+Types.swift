//
//  CloudKitRecordSyncManager+Types.swift
//  Pin It
//

import CloudKit
import Foundation

extension CloudKitRecordSyncManager {
    struct RemoteTombstone {
        var deletedRecordType: CloudKitRecordType
        var deletedRecordName: String
        var deletionTime: Int64
    }

    struct PhysicalDeletedRecord {
        var recordName: String
        var recordType: CloudKitRecordType?
    }

    struct RemoteChangeSet {
        var activeRecordsByType: [CloudKitRecordType: [CKRecord]]
        var tombstonesByDeletedRecordName: [String: RemoteTombstone]
        var hasUnexplainedPhysicalDeletes: Bool
        var zoneResetGeneration: String?
    }

    struct FetchAccumulator {
        var isFullSnapshot: Bool
        var prunesMissingLocalRecords: Bool
        var probesZoneDiscontinuity: Bool = false
        var changedRecords: [CKRecord] = []
        var physicalDeletedRecords: [PhysicalDeletedRecord] = []
    }

    struct FreshEngineMode {
        var bootstrapsLocalRecords: Bool
        var prunesMissingLocalRecords: Bool
        var probesZoneDiscontinuity: Bool = false
    }

    struct ServerRecordState {
        var recordsByRecordName: [String: CKRecord]
        var activeRecordsByRecordName: [String: CKRecord]
        var tombstonesByDeletedRecordName: [String: RemoteTombstone]
    }

    struct StagedImageAssets {
        var originalName: String?
        var processedName: String?

        var copiedFiles: [(String, CacheImageType)] {
            var files: [(String, CacheImageType)] = []
            if let originalName {
                files.append((originalName, .original))
            }
            if let processedName {
                files.append((processedName, .processed))
            }
            return files
        }
    }

    enum DependencyState {
        case available(Int64)
        case deleted(Int64)
        case missing
    }

    enum Field {
        static let syncId = "syncId"
        static let creationTime = "creationTime"
        static let modificationTime = "modificationTime"
        static let isDeleted = "isDeleted"

        static let expirationTime = "expirationTime"
        static let actionLink = "actionLink"
        static let isPinned = "isPinned"
        static let order = "order"

        static let postSyncId = "postSyncId"
        static let content = "content"

        static let originalFileName = "originalFileName"
        static let processedFileName = "processedFileName"
        static let originalAsset = "originalAsset"
        static let processedAsset = "processedAsset"
        static let orientation = "orientation"
        static let minX = "minX"
        static let minY = "minY"
        static let maxX = "maxX"
        static let maxY = "maxY"

        static let name = "name"
        static let lockBackgroundColor = "lockBackgroundColor"
        static let lockTextColor = "lockTextColor"
        static let lockTextSize = "lockTextSize"
        static let lockTextAlignment = "lockTextAlignment"
        static let islandTextColor = "islandTextColor"
        static let islandTextSize = "islandTextSize"
        static let islandTextAlignment = "islandTextAlignment"
        static let symbol = "symbol"
        static let symbolColor = "symbolColor"
        static let symbolAngle = "symbolAngle"
        static let imageDisplayMode = "imageDisplayMode"
        static let controlAlpha = "controlAlpha"

        static let styleSyncId = "styleSyncId"
        static let defaultStyleSyncId = "defaultStyleSyncId"

        static let deletedRecordType = "deletedRecordType"
        static let deletedRecordName = "deletedRecordName"
        static let deletionTime = "deletionTime"

        static let resetGeneration = "resetGeneration"
    }
}
