//
//  CloudKitRecordSyncManager+Tombstones.swift
//  Pin It
//

import CloudKit
import Foundation
import GRDB

extension CloudKitRecordSyncManager {
    /// `tombstoneApplied` is true when the remote tombstone is canonical for this
    /// record (we deleted now, or it was already gone). It is false only when local
    /// is newer than the tombstone and we re-enqueued a save, in which case caller
    /// must NOT mark the metadata isDeleted=true.
    struct TombstoneApplyOutcome {
        var didChangeDatabase: Bool
        var deletedImageFiles: [(String, CacheImageType)]
        var tombstoneApplied: Bool
    }

    func applyTombstone(_ tombstone: RemoteTombstone, in db: Database) throws -> TombstoneApplyOutcome {
        switch tombstone.deletedRecordType {
        case .post:
            guard let syncId = CloudKitRecordName.syncId(from: tombstone.deletedRecordName, type: .post),
                  let post = try Post.filter(Column(Post.CodingKeys.syncId) == syncId).fetchOne(db),
                  let postId = post.id else {
                return TombstoneApplyOutcome(didChangeDatabase: false, deletedImageFiles: [], tombstoneApplied: true)
            }
            let images = try PostImage
                .filter(Column(PostImage.CodingKeys.postId) == postId)
                .fetchAll(db)
            let texts = try PostText
                .filter(Column(PostText.CodingKeys.postId) == postId)
                .fetchAll(db)
            let decorations = try PostDecoration
                .filter(Column(PostDecoration.CodingKeys.postId) == postId)
                .fetchAll(db)
            var graphModificationTime = post.modificationTime ?? 0
            for image in images {
                graphModificationTime = max(graphModificationTime, image.modificationTime ?? 0)
            }
            for text in texts {
                graphModificationTime = max(graphModificationTime, text.modificationTime ?? 0)
            }
            for decoration in decorations {
                graphModificationTime = max(graphModificationTime, decoration.modificationTime ?? 0)
            }
            guard tombstone.deletionTime >= graphModificationTime else {
                if graphModificationTime > (post.modificationTime ?? 0) {
                    try Post
                        .filter(Column(Post.CodingKeys.id) == postId)
                        .updateAll(db, Column(Post.CodingKeys.modificationTime).set(to: graphModificationTime))
                }
                try CloudKitOutboxEntry.enqueueSave(recordType: .post, syncId: post.syncId, modificationTime: graphModificationTime, in: db)
                return TombstoneApplyOutcome(didChangeDatabase: false, deletedImageFiles: [], tombstoneApplied: false)
            }
            for image in images {
                try CloudKitLocalTombstone.store(recordType: .image, recordName: image.cloudKitRecordName, deletionTime: tombstone.deletionTime, in: db)
                try enqueueCloudKitDeleteIfNeeded(recordType: .image, syncId: image.syncId, deletionTime: tombstone.deletionTime, in: db)
            }
            for text in texts {
                try CloudKitLocalTombstone.store(recordType: .text, recordName: text.cloudKitRecordName, deletionTime: tombstone.deletionTime, in: db)
                try enqueueCloudKitDeleteIfNeeded(recordType: .text, syncId: text.syncId, deletionTime: tombstone.deletionTime, in: db)
            }
            for decoration in decorations {
                try CloudKitLocalTombstone.store(recordType: .decoration, recordName: decoration.cloudKitRecordName, deletionTime: tombstone.deletionTime, in: db)
                try enqueueCloudKitDeleteIfNeeded(recordType: .decoration, syncId: decoration.syncId, deletionTime: tombstone.deletionTime, in: db)
            }
            try PostImage.deleteAll(db, ids: images.compactMap(\.id))
            try PostText.deleteAll(db, ids: texts.compactMap(\.id))
            try PostDecoration.deleteAll(db, ids: decorations.compactMap(\.id))
            try Post.deleteAll(db, ids: [postId])
            try OnboardingLocalRecord.unmark(recordType: .post, syncId: post.syncId, in: db)
            try OnboardingLocalRecord.unmark(recordType: .image, syncIds: images.map(\.syncId), in: db)
            try OnboardingLocalRecord.unmark(recordType: .text, syncIds: texts.map(\.syncId), in: db)
            try OnboardingLocalRecord.unmark(recordType: .decoration, syncIds: decorations.map(\.syncId), in: db)
            return TombstoneApplyOutcome(didChangeDatabase: true, deletedImageFiles: imageFiles(for: images), tombstoneApplied: true)
        case .text:
            guard let syncId = CloudKitRecordName.syncId(from: tombstone.deletedRecordName, type: .text),
                  let text = try PostText.filter(Column(PostText.CodingKeys.syncId) == syncId).fetchOne(db),
                  let textId = text.id else {
                return TombstoneApplyOutcome(didChangeDatabase: false, deletedImageFiles: [], tombstoneApplied: true)
            }
            guard tombstone.deletionTime >= (text.modificationTime ?? 0) else {
                try enqueueCloudKitSaveIfNeeded(recordType: .text, syncId: text.syncId, modificationTime: text.modificationTime, in: db)
                try enqueuePostGraphSaveIfNeeded(postId: text.postId, modificationTime: text.modificationTime, in: db)
                return TombstoneApplyOutcome(didChangeDatabase: false, deletedImageFiles: [], tombstoneApplied: false)
            }
            try bumpPostGraphForAppliedChildDelete(postId: text.postId, modificationTime: tombstone.deletionTime, in: db)
            try PostText.deleteAll(db, ids: [textId])
            try OnboardingLocalRecord.unmark(recordType: .text, syncId: text.syncId, in: db)
            return TombstoneApplyOutcome(didChangeDatabase: true, deletedImageFiles: [], tombstoneApplied: true)
        case .image:
            guard let syncId = CloudKitRecordName.syncId(from: tombstone.deletedRecordName, type: .image),
                  let image = try PostImage.filter(Column(PostImage.CodingKeys.syncId) == syncId).fetchOne(db),
                  let imageId = image.id else {
                return TombstoneApplyOutcome(didChangeDatabase: false, deletedImageFiles: [], tombstoneApplied: true)
            }
            guard tombstone.deletionTime >= (image.modificationTime ?? 0) else {
                try enqueueCloudKitSaveIfNeeded(recordType: .image, syncId: image.syncId, modificationTime: image.modificationTime, in: db)
                try enqueuePostGraphSaveIfNeeded(postId: image.postId, modificationTime: image.modificationTime, in: db)
                return TombstoneApplyOutcome(didChangeDatabase: false, deletedImageFiles: [], tombstoneApplied: false)
            }
            try bumpPostGraphForAppliedChildDelete(postId: image.postId, modificationTime: tombstone.deletionTime, in: db)
            try PostImage.deleteAll(db, ids: [imageId])
            try OnboardingLocalRecord.unmark(recordType: .image, syncId: image.syncId, in: db)
            return TombstoneApplyOutcome(didChangeDatabase: true, deletedImageFiles: imageFiles(for: [image]), tombstoneApplied: true)
        case .style:
            guard let syncId = CloudKitRecordName.syncId(from: tombstone.deletedRecordName, type: .style) else {
                return TombstoneApplyOutcome(didChangeDatabase: false, deletedImageFiles: [], tombstoneApplied: true)
            }
            let didClearPendingDefaultStyle = try DefaultStyle.clearPendingCloudKitDefaultStyleIfNeeded(syncId: syncId, in: db)
            guard let style = try PostStyle.filter(Column(PostStyle.CodingKeys.syncId) == syncId).fetchOne(db),
                  let styleId = style.id else {
                return TombstoneApplyOutcome(didChangeDatabase: didClearPendingDefaultStyle, deletedImageFiles: [], tombstoneApplied: true)
            }
            let decorations = try PostDecoration
                .filter(Column(PostDecoration.CodingKeys.styleId) == styleId)
                .fetchAll(db)
            var graphModificationTime = style.modificationTime ?? 0
            for decoration in decorations {
                graphModificationTime = max(graphModificationTime, decoration.modificationTime ?? 0)
            }
            guard tombstone.deletionTime >= graphModificationTime else {
                if graphModificationTime > (style.modificationTime ?? 0) {
                    try PostStyle
                        .filter(Column(PostStyle.CodingKeys.id) == styleId)
                        .updateAll(db, Column(PostStyle.CodingKeys.modificationTime).set(to: graphModificationTime))
                }
                try CloudKitOutboxEntry.enqueueSave(recordType: .style, syncId: style.syncId, modificationTime: graphModificationTime, in: db)
                return TombstoneApplyOutcome(didChangeDatabase: didClearPendingDefaultStyle, deletedImageFiles: [], tombstoneApplied: false)
            }
            let fallbackStyle = try PostStyle
                .filter(PostStyle.Columns.id != styleId)
                .order(PostStyle.Columns.id.asc)
                .fetchOne(db)
            for decoration in decorations {
                try CloudKitLocalTombstone.store(recordType: .decoration, recordName: decoration.cloudKitRecordName, deletionTime: tombstone.deletionTime, in: db)
                try enqueueCloudKitDeleteIfNeeded(recordType: .decoration, syncId: decoration.syncId, deletionTime: tombstone.deletionTime, in: db)
            }
            try PostDecoration.deleteAll(db, ids: decorations.compactMap(\.id))
            try PostStyle.deleteAll(db, ids: [styleId])
            if try DefaultStyle.replaceDeletedStyleIfNeeded(
                deletedStyle: style,
                fallbackStyle: fallbackStyle,
                modificationTime: tombstone.deletionTime,
                in: db
            ) {
                try CloudKitOutboxEntry.enqueueSetting(modificationTime: tombstone.deletionTime, in: db)
            }
            try OnboardingLocalRecord.unmark(recordType: .style, syncId: style.syncId, in: db)
            try OnboardingLocalRecord.unmark(recordType: .decoration, syncIds: decorations.map(\.syncId), in: db)
            return TombstoneApplyOutcome(didChangeDatabase: true, deletedImageFiles: [], tombstoneApplied: true)
        case .decoration:
            guard let syncId = CloudKitRecordName.syncId(from: tombstone.deletedRecordName, type: .decoration),
                  let decoration = try PostDecoration.filter(Column(PostDecoration.CodingKeys.syncId) == syncId).fetchOne(db),
                  let decorationId = decoration.id else {
                return TombstoneApplyOutcome(didChangeDatabase: false, deletedImageFiles: [], tombstoneApplied: true)
            }
            guard tombstone.deletionTime >= (decoration.modificationTime ?? 0) else {
                try enqueueCloudKitSaveIfNeeded(recordType: .decoration, syncId: decoration.syncId, modificationTime: decoration.modificationTime, in: db)
                try enqueuePostGraphSaveIfNeeded(postId: decoration.postId, modificationTime: decoration.modificationTime, in: db)
                try enqueueStyleGraphSaveIfNeeded(styleId: decoration.styleId, modificationTime: decoration.modificationTime, in: db)
                return TombstoneApplyOutcome(didChangeDatabase: false, deletedImageFiles: [], tombstoneApplied: false)
            }
            try bumpPostGraphForAppliedChildDelete(postId: decoration.postId, modificationTime: tombstone.deletionTime, in: db)
            try bumpStyleGraphForAppliedChildDelete(styleId: decoration.styleId, modificationTime: tombstone.deletionTime, in: db)
            try PostDecoration.deleteAll(db, ids: [decorationId])
            try OnboardingLocalRecord.unmark(recordType: .decoration, syncId: decoration.syncId, in: db)
            return TombstoneApplyOutcome(didChangeDatabase: true, deletedImageFiles: [], tombstoneApplied: true)
        case .setting:
            let setting = try CloudKitSettingRecord.current(in: db)
            guard tombstone.deletedRecordName == CloudKitRecordName.settingsName,
                  tombstone.deletionTime >= setting.defaultStyleModificationTime else {
                return TombstoneApplyOutcome(didChangeDatabase: false, deletedImageFiles: [], tombstoneApplied: false)
            }
            let didChange = try DefaultStyle.clearCloudKitStateForMissingRemoteSetting(in: db)
            return TombstoneApplyOutcome(didChangeDatabase: didChange, deletedImageFiles: [], tombstoneApplied: true)
        }
    }

    func bumpPostGraphForAppliedChildDelete(postId: Int64, modificationTime: Int64, in db: Database) throws {
        guard let post = try Post.fetchOne(db, id: postId) else { return }
        if (post.modificationTime ?? 0) < modificationTime {
            try Post
                .filter(Column(Post.CodingKeys.id) == postId)
                .updateAll(db, Column(Post.CodingKeys.modificationTime).set(to: modificationTime))
        }
        guard try !OnboardingLocalRecord.isMarked(recordType: .post, syncId: post.syncId, in: db) else { return }
        try CloudKitOutboxEntry.enqueueSave(recordType: .post, syncId: post.syncId, modificationTime: modificationTime, in: db)
    }

    func bumpStyleGraphForAppliedChildDelete(styleId: Int64, modificationTime: Int64, in db: Database) throws {
        guard let style = try PostStyle.fetchOne(db, id: styleId) else { return }
        if (style.modificationTime ?? 0) < modificationTime {
            try PostStyle
                .filter(Column(PostStyle.CodingKeys.id) == styleId)
                .updateAll(db, Column(PostStyle.CodingKeys.modificationTime).set(to: modificationTime))
        }
        guard try !OnboardingLocalRecord.isMarked(recordType: .style, syncId: style.syncId, in: db) else { return }
        try CloudKitOutboxEntry.enqueueSave(recordType: .style, syncId: style.syncId, modificationTime: modificationTime, in: db)
    }

    func imageFiles(for images: [PostImage]) -> [(String, CacheImageType)] {
        images.flatMap { image in
            [(image.original, .original), (image.processed, .processed)]
        }
    }

    func cleanupCopiedImageFiles(_ copiedImageFiles: [(String, CacheImageType)]) {
        for (fileName, type) in copiedImageFiles {
            _ = ImageCacheManager.shared.deleteImage(fileName: fileName, type: type)
        }
    }
}
