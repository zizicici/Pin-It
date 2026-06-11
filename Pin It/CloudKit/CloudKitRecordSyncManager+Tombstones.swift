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

    /// How a cascade child tombstone relates to its parent graph on THIS device.
    private enum CascadeArbitration {
        /// The parent row is gone (the cascade already applied here, or the
        /// parent never existed): apply the child delete, but skip the
        /// individual-delete graph bump — the parent is dead or dying.
        case parentGone
        /// The parent graph lost against the deletion evidence: the whole
        /// family survives; rescue the child instead of deleting it.
        case parentSurvives
        /// The deletion evidence beats the parent graph: the cascade wins.
        case cascadeWins
        /// No cascade applies (tag mismatch with the local row's parents):
        /// fall back to per-record arbitration.
        case notACascade
    }

    func applyTombstone(
        _ tombstone: RemoteTombstone,
        batchTombstones: [String: RemoteTombstone],
        pendingDeletes: [String: CloudKitOutboxEntry],
        in db: Database
    ) throws -> TombstoneApplyOutcome {
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
                try CloudKitLocalTombstone.store(recordType: .image, recordName: image.cloudKitRecordName, deletionTime: tombstone.deletionTime, aggregateType: .postGraph, aggregateName: tombstone.deletedRecordName, in: db)
                try enqueueCloudKitDeleteIfNeeded(recordType: .image, syncId: image.syncId, deletionTime: tombstone.deletionTime, aggregateType: .postGraph, aggregateName: tombstone.deletedRecordName, in: db)
            }
            for text in texts {
                try CloudKitLocalTombstone.store(recordType: .text, recordName: text.cloudKitRecordName, deletionTime: tombstone.deletionTime, aggregateType: .postGraph, aggregateName: tombstone.deletedRecordName, in: db)
                try enqueueCloudKitDeleteIfNeeded(recordType: .text, syncId: text.syncId, deletionTime: tombstone.deletionTime, aggregateType: .postGraph, aggregateName: tombstone.deletedRecordName, in: db)
            }
            for decoration in decorations {
                try CloudKitLocalTombstone.store(recordType: .decoration, recordName: decoration.cloudKitRecordName, deletionTime: tombstone.deletionTime, aggregateType: .postGraph, aggregateName: tombstone.deletedRecordName, in: db)
                try enqueueCloudKitDeleteIfNeeded(recordType: .decoration, syncId: decoration.syncId, deletionTime: tombstone.deletionTime, aggregateType: .postGraph, aggregateName: tombstone.deletedRecordName, in: db)
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
            let parentPost = try Post.fetchOne(db, id: text.postId)
            switch try arbitratePostCascade(
                for: tombstone,
                parentPost: parentPost,
                childPostId: text.postId,
                batchTombstones: batchTombstones,
                pendingDeletes: pendingDeletes,
                in: db
            ) {
            case .parentGone, .cascadeWins:
                try PostText.deleteAll(db, ids: [textId])
                try OnboardingLocalRecord.unmark(recordType: .text, syncId: text.syncId, in: db)
                return TombstoneApplyOutcome(didChangeDatabase: true, deletedImageFiles: [], tombstoneApplied: true)
            case .parentSurvives:
                let rescueTime = max(text.modificationTime ?? 0, tombstone.deletionTime + 1)
                try PostText
                    .filter(Column(PostText.CodingKeys.id) == textId)
                    .updateAll(db, Column(PostText.CodingKeys.modificationTime).set(to: rescueTime))
                try enqueueCloudKitSaveIfNeeded(recordType: .text, syncId: text.syncId, modificationTime: rescueTime, in: db)
                try enqueuePostGraphSaveIfNeeded(postId: text.postId, modificationTime: rescueTime, in: db)
                return TombstoneApplyOutcome(didChangeDatabase: false, deletedImageFiles: [], tombstoneApplied: false)
            case .notACascade:
                break
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
            let parentPost = try Post.fetchOne(db, id: image.postId)
            switch try arbitratePostCascade(
                for: tombstone,
                parentPost: parentPost,
                childPostId: image.postId,
                batchTombstones: batchTombstones,
                pendingDeletes: pendingDeletes,
                in: db
            ) {
            case .parentGone, .cascadeWins:
                try PostImage.deleteAll(db, ids: [imageId])
                try OnboardingLocalRecord.unmark(recordType: .image, syncId: image.syncId, in: db)
                return TombstoneApplyOutcome(didChangeDatabase: true, deletedImageFiles: imageFiles(for: [image]), tombstoneApplied: true)
            case .parentSurvives:
                let rescueTime = max(image.modificationTime ?? 0, tombstone.deletionTime + 1)
                try PostImage
                    .filter(Column(PostImage.CodingKeys.id) == imageId)
                    .updateAll(db, Column(PostImage.CodingKeys.modificationTime).set(to: rescueTime))
                try enqueueCloudKitSaveIfNeeded(recordType: .image, syncId: image.syncId, modificationTime: rescueTime, in: db)
                try enqueuePostGraphSaveIfNeeded(postId: image.postId, modificationTime: rescueTime, in: db)
                return TombstoneApplyOutcome(didChangeDatabase: false, deletedImageFiles: [], tombstoneApplied: false)
            case .notACascade:
                break
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
                try CloudKitLocalTombstone.store(recordType: .decoration, recordName: decoration.cloudKitRecordName, deletionTime: tombstone.deletionTime, aggregateType: .styleGraph, aggregateName: tombstone.deletedRecordName, in: db)
                try enqueueCloudKitDeleteIfNeeded(recordType: .decoration, syncId: decoration.syncId, deletionTime: tombstone.deletionTime, aggregateType: .styleGraph, aggregateName: tombstone.deletedRecordName, in: db)
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
            let parentPost = try Post.fetchOne(db, id: decoration.postId)
            let parentStyle = try PostStyle.fetchOne(db, id: decoration.styleId)
            let arbitration: CascadeArbitration
            var diesWithStyleCascade = false
            if let cascadeParent = tombstone.cascadeParentRecordName ?? legacyCascadeParent(
                for: tombstone,
                localParentRecordNames: [
                    parentPost.map { CloudKitRecordName.make(.post, syncId: $0.syncId) },
                    parentStyle.map { CloudKitRecordName.make(.style, syncId: $0.syncId) }
                ].compactMap { $0 },
                batchTombstones: batchTombstones
            ) {
                if CloudKitRecordName.syncId(from: cascadeParent, type: .style) != nil {
                    diesWithStyleCascade = true
                    var styleGraphTime: Int64?
                    if let parentStyle {
                        styleGraphTime = try styleGraphModificationTime(styleId: decoration.styleId, style: parentStyle, in: db)
                    }
                    arbitration = try arbitrateCascade(
                        parentRecordName: cascadeParent,
                        localParentRecordName: parentStyle.map { CloudKitRecordName.make(.style, syncId: $0.syncId) },
                        parentGraphModificationTime: styleGraphTime,
                        childDeletionTime: tombstone.deletionTime,
                        batchTombstones: batchTombstones,
                        pendingDeletes: pendingDeletes,
                        in: db
                    )
                } else {
                    var postGraphTime: Int64?
                    if let parentPost {
                        postGraphTime = try postGraphModificationTime(postId: decoration.postId, post: parentPost, in: db)
                    }
                    arbitration = try arbitrateCascade(
                        parentRecordName: cascadeParent,
                        localParentRecordName: parentPost.map { CloudKitRecordName.make(.post, syncId: $0.syncId) },
                        parentGraphModificationTime: postGraphTime,
                        childDeletionTime: tombstone.deletionTime,
                        batchTombstones: batchTombstones,
                        pendingDeletes: pendingDeletes,
                        in: db
                    )
                }
            } else {
                arbitration = .notACascade
            }
            switch arbitration {
            case .parentGone, .cascadeWins:
                if diesWithStyleCascade {
                    // Mirror the deleter: delete(style:) touches the affected
                    // posts at the deletion time (the post survives a style
                    // cascade and its appearance changed).
                    try bumpPostGraphForAppliedChildDelete(postId: decoration.postId, modificationTime: tombstone.deletionTime, in: db)
                }
                try PostDecoration.deleteAll(db, ids: [decorationId])
                try OnboardingLocalRecord.unmark(recordType: .decoration, syncId: decoration.syncId, in: db)
                return TombstoneApplyOutcome(didChangeDatabase: true, deletedImageFiles: [], tombstoneApplied: true)
            case .parentSurvives:
                let rescueTime = max(decoration.modificationTime ?? 0, tombstone.deletionTime + 1)
                try PostDecoration
                    .filter(Column(PostDecoration.CodingKeys.id) == decorationId)
                    .updateAll(db, Column(PostDecoration.CodingKeys.modificationTime).set(to: rescueTime))
                try enqueueCloudKitSaveIfNeeded(recordType: .decoration, syncId: decoration.syncId, modificationTime: rescueTime, in: db)
                try enqueuePostGraphSaveIfNeeded(postId: decoration.postId, modificationTime: rescueTime, in: db)
                try enqueueStyleGraphSaveIfNeeded(styleId: decoration.styleId, modificationTime: rescueTime, in: db)
                return TombstoneApplyOutcome(didChangeDatabase: false, deletedImageFiles: [], tombstoneApplied: false)
            case .notACascade:
                break
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

    /// Cascade arbitration for text/image/decoration tombstones whose parent
    /// is a post. The cascade wins only when the parent's deletion evidence
    /// beats the parent's whole-graph modification time — the same expression
    /// the `.post` tombstone case evaluates, so every member of one cascade
    /// reaches the same verdict regardless of batch iteration order.
    private func arbitratePostCascade(
        for tombstone: RemoteTombstone,
        parentPost: Post?,
        childPostId: Int64,
        batchTombstones: [String: RemoteTombstone],
        pendingDeletes: [String: CloudKitOutboxEntry],
        in db: Database
    ) throws -> CascadeArbitration {
        let localParentName = parentPost.map { CloudKitRecordName.make(.post, syncId: $0.syncId) }
        guard let cascadeParent = tombstone.cascadeParentRecordName ?? legacyCascadeParent(
            for: tombstone,
            localParentRecordNames: [localParentName].compactMap { $0 },
            batchTombstones: batchTombstones
        ), CloudKitRecordName.syncId(from: cascadeParent, type: .post) != nil else {
            return .notACascade
        }
        var graphTime: Int64?
        if let parentPost {
            graphTime = try postGraphModificationTime(postId: childPostId, post: parentPost, in: db)
        }
        return try arbitrateCascade(
            parentRecordName: cascadeParent,
            localParentRecordName: localParentName,
            parentGraphModificationTime: graphTime,
            childDeletionTime: tombstone.deletionTime,
            batchTombstones: batchTombstones,
            pendingDeletes: pendingDeletes,
            in: db
        )
    }

    private func arbitrateCascade(
        parentRecordName: String,
        localParentRecordName: String?,
        parentGraphModificationTime: Int64?,
        childDeletionTime: Int64,
        batchTombstones: [String: RemoteTombstone],
        pendingDeletes: [String: CloudKitOutboxEntry],
        in db: Database
    ) throws -> CascadeArbitration {
        guard let localParentRecordName else {
            return .parentGone
        }
        guard localParentRecordName == parentRecordName else {
            // The local row hangs off a different parent than the cascade
            // tag claims — inconsistent; the per-record rules are the only
            // safe arbitration.
            return .notACascade
        }
        guard let parentGraphModificationTime else {
            return .notACascade
        }
        var evidenceTime: Int64?
        if let batchTombstone = batchTombstones[parentRecordName] {
            evidenceTime = max(evidenceTime ?? 0, batchTombstone.deletionTime)
        }
        if let localTombstone = try CloudKitLocalTombstone.fetchOne(db, key: parentRecordName) {
            evidenceTime = max(evidenceTime ?? 0, localTombstone.deletionTime)
        }
        if let pendingDelete = pendingDeletes[parentRecordName] {
            evidenceTime = max(evidenceTime ?? 0, pendingDelete.modificationTime)
        }
        // A cascade-tagged child tombstone is itself evidence the parent was
        // deleted at the cascade's deletionTime — sends are not atomic
        // (chunked batches, per-record failures), so the parent tombstone
        // may simply not have arrived yet. Without this, a partially-visible
        // cascade would "rescue" (resurrect) a deliberately deleted family.
        // Legitimate rescues are unaffected: there the graph carries an edit
        // newer than the cascade's deletionTime.
        let effectiveEvidenceTime = max(evidenceTime ?? 0, childDeletionTime)
        return effectiveEvidenceTime >= parentGraphModificationTime ? .cascadeWins : .parentSurvives
    }

    /// Legacy cascade detection for tombstones written before cascade tagging:
    /// cascade members share their delete transaction's date, so a same-batch
    /// parent tombstone with the exact same deletionTime identifies the group.
    private func legacyCascadeParent(
        for tombstone: RemoteTombstone,
        localParentRecordNames: [String],
        batchTombstones: [String: RemoteTombstone]
    ) -> String? {
        for parentName in localParentRecordNames {
            if let parentTombstone = batchTombstones[parentName],
               parentTombstone.deletionTime == tombstone.deletionTime {
                return parentName
            }
        }
        return nil
    }

    func postGraphModificationTime(postId: Int64, post: Post, in db: Database) throws -> Int64 {
        var graphModificationTime = post.modificationTime ?? 0
        for image in try PostImage.filter(Column(PostImage.CodingKeys.postId) == postId).fetchAll(db) {
            graphModificationTime = max(graphModificationTime, image.modificationTime ?? 0)
        }
        for text in try PostText.filter(Column(PostText.CodingKeys.postId) == postId).fetchAll(db) {
            graphModificationTime = max(graphModificationTime, text.modificationTime ?? 0)
        }
        for decoration in try PostDecoration.filter(Column(PostDecoration.CodingKeys.postId) == postId).fetchAll(db) {
            graphModificationTime = max(graphModificationTime, decoration.modificationTime ?? 0)
        }
        return graphModificationTime
    }

    func styleGraphModificationTime(styleId: Int64, style: PostStyle, in db: Database) throws -> Int64 {
        var graphModificationTime = style.modificationTime ?? 0
        for decoration in try PostDecoration.filter(Column(PostDecoration.CodingKeys.styleId) == styleId).fetchAll(db) {
            graphModificationTime = max(graphModificationTime, decoration.modificationTime ?? 0)
        }
        return graphModificationTime
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
