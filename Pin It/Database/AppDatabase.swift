//
//  AppDatabase.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/17.
//

import CryptoKit
import Foundation
import GRDB

extension Notification.Name {
    static let DatabaseUpdated = Notification.Name(rawValue: "com.zizicici.common.database.updated")
    static let DatabaseStyleUpdated = Notification.Name(rawValue: "com.zizicici.common.database.updated.style")
}

private enum AppDatabaseError: LocalizedError {
    case missingPost(Int64)
    case missingText(Int64)
    case missingImage(Int64)
    case missingStyle(Int64)
    case missingDecoration(Int64)
    case insertedPostHasNoID

    var errorDescription: String? {
        switch self {
        case .missingPost(let id):
            return "Missing post \(id)"
        case .missingText(let id):
            return "Missing text \(id)"
        case .missingImage(let id):
            return "Missing image \(id)"
        case .missingStyle(let id):
            return "Missing style \(id)"
        case .missingDecoration(let id):
            return "Missing decoration \(id)"
        case .insertedPostHasNoID:
            return "Inserted post is missing an id"
        }
    }
}

final class AppDatabase {
    init(_ dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try migrator.migrate(dbWriter)
    }
    
    private(set) var dbWriter: (any DatabaseWriter)?

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
#if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
#endif
        migrator.registerMigration("post____content____record") { db in
            try db.create(table: "post") { table in
                table.autoIncrementedPrimaryKey("id")
                
                table.column("creation_time", .integer).notNull()
                table.column("modification_time", .integer).notNull()
                
                table.column("is_pinned", .boolean).notNull()
                table.column("order", .integer).notNull()
            }
            try db.create(table: "text") { table in
                table.autoIncrementedPrimaryKey("id")
                
                table.column("post_id", .integer).notNull()
                    .indexed()
                    .references("post", onDelete: .cascade)
                
                table.column("content", .text).notNull()
                
                table.column("order", .integer).notNull()
            }
            try db.create(table: "image") { table in
                table.autoIncrementedPrimaryKey("id")
                
                table.column("post_id", .integer).notNull()
                    .indexed()
                    .references("post", onDelete: .cascade)
                
                table.column("original", .text).notNull()
                table.column("processed", .text).notNull()
                table.column("orientation", .integer).notNull()
                table.column("min_x", .integer).notNull()
                table.column("min_y", .integer).notNull()
                table.column("max_x", .integer).notNull()
                table.column("max_y", .integer).notNull()
                
                table.column("order", .integer).notNull()
            }
        }
        
        migrator.registerMigration("post____expiration___time") { db in
            try db.alter(table: "post") { table in
                table.add(column: "expiration_time", .integer)
            }
        }
        
        migrator.registerMigration("post____style___decoration") { db in
            try db.create(table: "style") { table in
                table.autoIncrementedPrimaryKey("id")
                
                table.column("name", .text).notNull()
                
                table.column("lock_background_color", .text)
                table.column("lock_text_color", .text)
                table.column("lock_text_size", .integer).notNull()
                table.column("lock_text_alignment", .integer).notNull()
                
                table.column("island_text_color", .text)
                table.column("island_text_size", .integer).notNull()
                table.column("island_text_alignment", .integer).notNull()
                
                table.column("symbol", .text).notNull()
                table.column("symbol_color", .text)
                table.column("symbol_angle", .integer) // angle * 100
                
                table.column("image_display_mode", .integer).notNull()
                
                table.column("control_alpha", .integer).notNull()
            }
            
            try db.create(table: "decoration") { table in
                table.autoIncrementedPrimaryKey("id")
                
                table.column("post_id", .integer).notNull()
                    .indexed()
                    .references("post", onDelete: .cascade)
                
                table.column("style_id", .integer).notNull()
                    .indexed()
                    .references("style", onDelete: .cascade)
            }
        }
        
        migrator.registerMigration("post____action____link") { db in
            try db.alter(table: "post") { table in
                table.add(column: "action_link", .text).notNull()
                    .defaults(to: "")
            }
        }
        
        migrator.registerMigration("cloudkit____record____sync") { db in
            let legacyTimestamp = try db.transactionDate.nanoSecondSince1970

            func deterministicSyncId(seed: String) -> String {
                // SHA-256 truncated to 128 bits, version/variant nibbles overwritten
                // so the result parses as an RFC 4122 v5-shaped UUID. We're not using
                // SHA-1, but downstream parsers only sniff the version/variant bits.
                var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
                bytes[6] = (bytes[6] & 0x0F) | 0x50
                bytes[8] = (bytes[8] & 0x3F) | 0x80
                let uuid = bytes.withUnsafeBytes { $0.load(as: uuid_t.self) }
                return UUID(uuid: uuid).uuidString
            }

            func addCloudKitRecordColumns(_ table: TableDefinition) {
                table.column("sync_id", .text).notNull().defaults(to: "")
                table.column("creation_time", .integer).notNull().defaults(to: legacyTimestamp)
                table.column("modification_time", .integer).notNull().defaults(to: legacyTimestamp)
            }

            func deleteOrphanedChildren() throws {
                try db.execute(sql: "DELETE FROM text WHERE NOT EXISTS (SELECT 1 FROM post WHERE post.id = text.post_id)")
                try db.execute(sql: "DELETE FROM image WHERE NOT EXISTS (SELECT 1 FROM post WHERE post.id = image.post_id)")
                try db.execute(sql: """
                    DELETE FROM decoration
                    WHERE NOT EXISTS (SELECT 1 FROM post WHERE post.id = decoration.post_id)
                       OR NOT EXISTS (SELECT 1 FROM style WHERE style.id = decoration.style_id)
                """)
                try db.execute(sql: """
                    DELETE FROM decoration
                    WHERE EXISTS (
                        SELECT 1
                        FROM post
                        WHERE post.id = decoration.post_id
                          AND NOT EXISTS (SELECT 1 FROM text WHERE text.post_id = post.id)
                          AND NOT EXISTS (SELECT 1 FROM image WHERE image.post_id = post.id)
                    )
                """)
                try db.execute(sql: """
                    DELETE FROM post
                    WHERE NOT EXISTS (SELECT 1 FROM text WHERE text.post_id = post.id)
                      AND NOT EXISTS (SELECT 1 FROM image WHERE image.post_id = post.id)
                """)
            }

            func rebuildTableWithoutForeignKeys(
                _ tableName: String,
                copyColumns: String,
                body: (TableDefinition) throws -> Void
            ) throws {
                let oldSequence = try sqliteSequence(for: tableName)
                let temporaryTableName = "\(tableName)_without_foreign_keys"
                try db.create(table: temporaryTableName, body: body)
                try db.execute(sql: """
                    INSERT INTO \(temporaryTableName) (\(copyColumns))
                    SELECT \(copyColumns) FROM \(tableName)
                """)
                try db.drop(table: tableName)
                try db.rename(table: temporaryTableName, to: tableName)
                try restoreSQLiteSequence(for: tableName, toAtLeast: oldSequence)
            }

            func sqliteSequence(for tableName: String) throws -> Int64? {
                let row = try Table("sqlite_sequence")
                    .select(Column("seq"))
                    .filter(Column("name") == tableName)
                    .fetchOne(db)
                return row?["seq"]
            }

            func restoreSQLiteSequence(for tableName: String, toAtLeast oldSequence: Int64?) throws {
                guard let oldSequence else { return }
                let currentSequence = try sqliteSequence(for: tableName) ?? 0
                let sequence = max(oldSequence, currentSequence)
                guard sequence > currentSequence else { return }

                let updatedCount = try Table("sqlite_sequence")
                    .filter(Column("name") == tableName)
                    .updateAll(db, Column("seq").set(to: sequence))
                if updatedCount == 0 {
                    try db.execute(
                        sql: "INSERT INTO sqlite_sequence (name, seq) VALUES (?, ?)",
                        arguments: [tableName, sequence]
                    )
                }
            }

            try db.alter(table: "post") { table in
                table.add(column: "sync_id", .text).notNull().defaults(to: "")
            }
            try db.alter(table: "style") { table in
                table.add(column: "sync_id", .text).notNull().defaults(to: "")
                table.add(column: "creation_time", .integer).notNull().defaults(to: legacyTimestamp)
                table.add(column: "modification_time", .integer).notNull().defaults(to: legacyTimestamp)
            }

            try deleteOrphanedChildren()

            try rebuildTableWithoutForeignKeys("text", copyColumns: #"id, post_id, content, "order""#) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("post_id", .integer).notNull()
                table.column("content", .text).notNull()
                table.column("order", .integer).notNull()
                addCloudKitRecordColumns(table)
            }

            try rebuildTableWithoutForeignKeys(
                "image",
                copyColumns: #"id, post_id, original, processed, orientation, min_x, min_y, max_x, max_y, "order""#
            ) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("post_id", .integer).notNull()
                table.column("original", .text).notNull()
                table.column("processed", .text).notNull()
                table.column("orientation", .integer).notNull()
                table.column("min_x", .integer).notNull()
                table.column("min_y", .integer).notNull()
                table.column("max_x", .integer).notNull()
                table.column("max_y", .integer).notNull()
                table.column("order", .integer).notNull()
                addCloudKitRecordColumns(table)
            }

            try rebuildTableWithoutForeignKeys("decoration", copyColumns: "id, post_id, style_id") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("post_id", .integer).notNull()
                table.column("style_id", .integer).notNull()
                addCloudKitRecordColumns(table)
            }

            func backfillSyncIds(in tableName: String) throws {
                // Random UUIDs, NOT deterministic. Two devices that each have legacy
                // pre-CloudKit data have INDEPENDENT records that just happen to share
                // SQLite ids; deriving the sync_id from (tableName, id) would make
                // device A's post.1 and device B's post.1 collide on CloudKit and
                // overwrite each other on first sync. Deterministic IDs are still used
                // downstream (mixedBodyPostRows split) but only as a function of an
                // already-unique syncId, so they remain device-distinct.
                let rows = try Table(tableName)
                    .select(Column("id"))
                    .filter(Column("sync_id") == nil || Column("sync_id") == "")
                    .fetchAll(db)
                for row in rows {
                    let id: Int64 = row["id"]
                    try Table(tableName)
                        .filter(Column("id") == id)
                        .updateAll(db, Column("sync_id").set(to: UUID().uuidString))
                }
            }

            for tableName in ["post", "text", "image", "style", "decoration"] {
                try backfillSyncIds(in: tableName)
            }

            try db.execute(
                sql: "UPDATE style SET creation_time = ? + id, modification_time = ? + id",
                arguments: [legacyTimestamp, legacyTimestamp]
            )

            try db.execute(sql: """
                UPDATE text
                SET creation_time = COALESCE((SELECT post.creation_time FROM post WHERE post.id = text.post_id), creation_time),
                    modification_time = COALESCE((SELECT post.modification_time FROM post WHERE post.id = text.post_id), modification_time)
            """)
            try db.execute(sql: """
                UPDATE image
                SET creation_time = COALESCE((SELECT post.creation_time FROM post WHERE post.id = image.post_id), creation_time),
                    modification_time = COALESCE((SELECT post.modification_time FROM post WHERE post.id = image.post_id), modification_time)
            """)
            try db.execute(sql: """
                UPDATE decoration
                SET creation_time = COALESCE((SELECT post.creation_time FROM post WHERE post.id = decoration.post_id), creation_time),
                    modification_time = COALESCE((SELECT post.modification_time FROM post WHERE post.id = decoration.post_id), modification_time)
            """)

            let mixedBodyPostRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT post.*
                    FROM post
                    JOIN text ON text.post_id = post.id
                    JOIN image ON image.post_id = post.id
                """
            )
            func nextPostOrder(isPinned: Bool) throws -> Int64 {
                try Int64.fetchOne(
                    db,
                    sql: #"SELECT COALESCE(MAX("order"), -1) + 1 FROM post WHERE is_pinned = ?"#,
                    arguments: [isPinned]
                ) ?? 0
            }

            var nextOrderByPinnedState: [Bool: Int64] = [
                false: try nextPostOrder(isPinned: false),
                true: try nextPostOrder(isPinned: true)
            ]
            for row in mixedBodyPostRows {
                let postId: Int64 = row["id"]
                let originalSyncId: String = row["sync_id"]
                let creationTime: Int64 = row["creation_time"]
                let modificationTime: Int64 = row["modification_time"]
                // The split-out text post must not inherit the pinned state:
                // with MaxPinnedPosts == .one the original and the copy would
                // otherwise both be pinned after migration. (The original post
                // keeps its is_pinned untouched.)
                let newPostIsPinned = false
                let nextOrder = nextOrderByPinnedState[newPostIsPinned] ?? 0
                let expirationTime: Int64? = row["expiration_time"]
                let actionLink: String = row["action_link"]
                let bumpedOriginalModTime = max(modificationTime, legacyTimestamp + postId)
                try db.execute(
                    sql: "UPDATE post SET modification_time = ? WHERE id = ?",
                    arguments: [bumpedOriginalModTime, postId]
                )
                let newPostSyncId = deterministicSyncId(seed: "split-text:\(originalSyncId)")
                let newPostModTime = bumpedOriginalModTime + 1
                try db.execute(
                    sql: """
                        INSERT INTO post (
                            creation_time,
                            modification_time,
                            is_pinned,
                            "order",
                            expiration_time,
                            action_link,
                            sync_id
                        ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        creationTime,
                        newPostModTime,
                        newPostIsPinned,
                        nextOrder,
                        expirationTime,
                        actionLink,
                        newPostSyncId
                    ]
                )
                let newPostId = db.lastInsertedRowID
                try db.execute(
                    sql: "UPDATE text SET post_id = ? WHERE post_id = ?",
                    arguments: [newPostId, postId]
                )
                let decorations = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM decoration WHERE post_id = ?",
                    arguments: [postId]
                )
                for decoration in decorations {
                    let styleId: Int64 = decoration["style_id"]
                    let decorationOriginalSyncId: String = decoration["sync_id"]
                    let decorationCreationTime: Int64 = decoration["creation_time"]
                    let decorationModificationTime: Int64 = decoration["modification_time"]
                    try db.execute(
                        sql: """
                            INSERT INTO decoration (
                                post_id,
                                style_id,
                                sync_id,
                                creation_time,
                                modification_time
                            ) VALUES (?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            newPostId,
                            styleId,
                            deterministicSyncId(seed: "split-decoration:\(decorationOriginalSyncId)"),
                            decorationCreationTime,
                            decorationModificationTime
                        ]
                    )
                }
                nextOrderByPinnedState[newPostIsPinned] = nextOrder + 1
            }

            try db.execute(sql: """
                DELETE FROM decoration
                WHERE EXISTS (
                    SELECT 1
                    FROM decoration newer
                    WHERE newer.post_id = decoration.post_id
                      AND (
                          newer.modification_time > decoration.modification_time
                          OR (newer.modification_time = decoration.modification_time AND newer.id > decoration.id)
                      )
                )
            """)

            let indexes: [(name: String, table: String, columns: [String], unique: Bool)] = [
                ("text_post_id_idx", "text", ["post_id"], false),
                ("image_post_id_idx", "image", ["post_id"], false),
                ("decoration_post_id_unique_idx", "decoration", ["post_id"], true),
                ("decoration_style_id_idx", "decoration", ["style_id"], false),
                ("post_sync_id_idx", "post", ["sync_id"], true),
                ("text_sync_id_idx", "text", ["sync_id"], true),
                ("image_sync_id_idx", "image", ["sync_id"], true),
                ("style_sync_id_idx", "style", ["sync_id"], true),
                ("decoration_sync_id_idx", "decoration", ["sync_id"], true)
            ]
            for index in indexes {
                try db.create(index: index.name, on: index.table, columns: index.columns, unique: index.unique, ifNotExists: true)
            }

            try db.create(table: "cloudkit_outbox") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("record_type", .text).notNull()
                table.column("record_name", .text).notNull()
                table.column("operation", .text).notNull()
                table.column("modification_time", .integer).notNull()
                table.column("aggregate_type", .text).notNull().defaults(to: "record")
                table.column("aggregate_name", .text).notNull().defaults(to: "")
                table.column("local_version", .integer).notNull().defaults(to: 0)
                table.column("created_at", .integer).notNull()
                table.column("updated_at", .integer).notNull()
                table.column("retry_count", .integer).notNull().defaults(to: 0)
                table.column("last_error", .text)
                table.uniqueKey(["record_name"])
            }
            try db.create(index: "cloudkit_outbox_order_idx", on: "cloudkit_outbox", columns: ["updated_at", "id"], ifNotExists: true)

            try db.create(table: "cloudkit_sync_state") { table in
                table.primaryKey("key", .text)
                table.column("value", .blob)
            }

            try db.create(table: "cloudkit_tombstone") { table in
                table.primaryKey("record_name", .text)
                table.column("deleted_record_type", .text).notNull()
                table.column("deletion_time", .integer).notNull()
                table.column("updated_at", .integer).notNull()
            }

            try db.create(table: "local_onboarding_record") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("record_type", .text).notNull()
                table.column("sync_id", .text).notNull()
                table.uniqueKey(["record_type", "sync_id"], onConflict: .replace)
            }

            try db.create(table: "cloudkit_record_metadata") { table in
                table.primaryKey("record_name", .text)
                table.column("record_type", .text).notNull()
                table.column("aggregate_type", .text).notNull()
                table.column("aggregate_name", .text).notNull()
                table.column("local_version", .integer).notNull().defaults(to: 0)
                table.column("last_synced_version", .integer).notNull().defaults(to: 0)
                table.column("server_change_tag", .text)
                table.column("is_deleted", .boolean).notNull().defaults(to: false)
                table.column("last_error", .text)
                table.column("updated_at", .integer).notNull()
            }
            try db.create(index: "cloudkit_record_metadata_aggregate_idx", on: "cloudkit_record_metadata", columns: ["aggregate_type", "aggregate_name"])

            try db.create(table: "cloudkit_setting") { table in
                table.primaryKey("key", .text)
                table.column("default_style_sync_id", .text)
                table.column("default_style_modification_time", .integer).notNull().defaults(to: 0)
                table.column("pending_default_style_sync_id", .text)
                table.column("pending_default_style_modification_time", .integer)
                table.column("updated_at", .integer).notNull()
            }

            let defaults = UserDefaults(suiteName: appGroupId)
            func int64Default(forKey key: String) -> Int64? {
                if let value = defaults?.object(forKey: key) as? Int64 {
                    return value
                }
                if let value = defaults?.object(forKey: key) as? NSNumber {
                    return value.int64Value
                }
                return nil
            }
            let legacySyncId = defaults?.string(forKey: UserDefaults.Settings.DefaultStyleSyncId.rawValue)
            let legacyModificationTime = int64Default(forKey: UserDefaults.Settings.DefaultStyleModificationTime.rawValue) ?? 0
            let legacyPendingSyncId = defaults?.string(forKey: UserDefaults.Settings.DefaultStylePendingCloudKitSyncId.rawValue)
            let legacyPendingModificationTime = int64Default(forKey: UserDefaults.Settings.DefaultStylePendingCloudKitModificationTime.rawValue)
            try db.execute(
                sql: """
                    INSERT INTO cloudkit_setting (
                        key,
                        default_style_sync_id,
                        default_style_modification_time,
                        pending_default_style_sync_id,
                        pending_default_style_modification_time,
                        updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "default",
                    legacySyncId,
                    legacyModificationTime,
                    legacyPendingSyncId,
                    legacyPendingModificationTime,
                    Date().nanoSecondSince1970
                ]
            )
        }

        migrator.registerMigration("cloudkit____tombstone____cascade") { db in
            // Cascade tags: a tombstone created by deleting a whole post/style
            // records which graph it belonged to (and the parent's record
            // name), so delete-vs-edit conflicts are arbitrated per graph
            // instead of per record. Nullable; nil means an individual delete.
            try db.alter(table: "cloudkit_tombstone") { table in
                table.add(column: "aggregate_type", .text)
                table.add(column: "aggregate_name", .text)
            }
        }

        return migrator
    }

}

extension AppDatabase {
    func createTextPost(
        content: String,
        actionLink: String,
        isPinned: Bool,
        expirationTime: Int64?,
        styleId: Int64?,
        enforcesSinglePinnedPost: Bool
    ) -> Post? {
        var result: Post?
        do {
            try dbWriter?.write { db in
                if let styleId {
                    try requireStyle(styleId: styleId, in: db)
                }
                if isPinned, enforcesSinglePinnedPost {
                    try unpinAllPinnedPosts(in: db, promotesLocalOnboarding: false)
                }

                var post = Post(
                    expirationTime: expirationTime,
                    actionLink: actionLink,
                    isPinned: isPinned,
                    order: try nextPostOrder(isPinned: isPinned, in: db)
                )
                try post.save(db)
                guard let postId = post.id else {
                    throw AppDatabaseError.insertedPostHasNoID
                }
                try enqueueCloudKitSaveIfNeeded(recordType: .post, syncId: post.syncId, modificationTime: post.modificationTime, in: db)

                var text = PostText(postId: postId, content: content, order: 0)
                try text.save(db)
                try enqueueCloudKitSaveIfNeeded(recordType: .text, syncId: text.syncId, modificationTime: text.modificationTime, in: db)
                try touchPostForCloudKit(postId: postId, modificationTime: text.modificationTime, in: db)

                if let styleId {
                    try promoteStyleToUserContent(styleId: styleId, in: db)
                    var decoration = PostDecoration(styleId: styleId, postId: postId)
                    try decoration.save(db)
                    try enqueueCloudKitSaveIfNeeded(
                        recordType: .decoration,
                        syncId: decoration.syncId,
                        modificationTime: decoration.modificationTime,
                        in: db
                    )
                    try touchPostForCloudKit(postId: postId, modificationTime: decoration.modificationTime, in: db)
                    try touchStyleForCloudKit(styleId: styleId, modificationTime: decoration.modificationTime, in: db)
                }

                result = post
            }
        } catch {
            print(error)
            return nil
        }
        DatabaseUpdateNotifier.shared.post(.DatabaseUpdated)
        return result
    }

    func createImagePost(
        original: String,
        processed: String,
        rect: CGRect,
        orientation: Int,
        actionLink: String,
        isPinned: Bool,
        expirationTime: Int64?,
        styleId: Int64?,
        enforcesSinglePinnedPost: Bool
    ) -> Post? {
        var result: Post?
        do {
            try dbWriter?.write { db in
                if let styleId {
                    try requireStyle(styleId: styleId, in: db)
                }
                if isPinned, enforcesSinglePinnedPost {
                    try unpinAllPinnedPosts(in: db, promotesLocalOnboarding: false)
                }

                var post = Post(
                    expirationTime: expirationTime,
                    actionLink: actionLink,
                    isPinned: isPinned,
                    order: try nextPostOrder(isPinned: isPinned, in: db)
                )
                try post.save(db)
                guard let postId = post.id else {
                    throw AppDatabaseError.insertedPostHasNoID
                }
                try enqueueCloudKitSaveIfNeeded(recordType: .post, syncId: post.syncId, modificationTime: post.modificationTime, in: db)

                var image = PostImage(
                    postId: postId,
                    original: original,
                    processed: processed,
                    orientation: Int64(orientation),
                    minX: Int64(rect.minX),
                    minY: Int64(rect.minY),
                    maxX: Int64(rect.maxX),
                    maxY: Int64(rect.maxY),
                    order: 0
                )
                try image.save(db)
                try enqueueCloudKitSaveIfNeeded(recordType: .image, syncId: image.syncId, modificationTime: image.modificationTime, in: db)
                try touchPostForCloudKit(postId: postId, modificationTime: image.modificationTime, in: db)

                if let styleId {
                    try promoteStyleToUserContent(styleId: styleId, in: db)
                    var decoration = PostDecoration(styleId: styleId, postId: postId)
                    try decoration.save(db)
                    try enqueueCloudKitSaveIfNeeded(
                        recordType: .decoration,
                        syncId: decoration.syncId,
                        modificationTime: decoration.modificationTime,
                        in: db
                    )
                    try touchPostForCloudKit(postId: postId, modificationTime: decoration.modificationTime, in: db)
                    try touchStyleForCloudKit(styleId: styleId, modificationTime: decoration.modificationTime, in: db)
                }

                result = post
            }
        } catch {
            print(error)
            return nil
        }
        DatabaseUpdateNotifier.shared.post(.DatabaseUpdated)
        return result
    }

    func replacePostBodyWithText(postId: Int64, content: String) -> [PostImage]? {
        var deletedImages: [PostImage] = []
        do {
            try dbWriter?.write { db in
                try requirePost(postId: postId, in: db)
                let images = try PostImage
                    .filter(Column(PostImage.CodingKeys.postId) == postId)
                    .fetchAll(db)
                let texts = try PostText
                    .filter(Column(PostText.CodingKeys.postId) == postId)
                    .fetchAll(db)
                // The replacement must beat every old body row, or a peer's
                // exclusivity arbitration (newest body type wins) would delete
                // the replacement and resurrect the old bodies when an old
                // row's time came from a clock-ahead device.
                let maxBodyModificationTime = (images.map { $0.modificationTime ?? 0 } + texts.map { $0.modificationTime ?? 0 }).max()
                let replacementTime = try guardedDeletionTime(rowModificationTime: maxBodyModificationTime, in: db)
                for image in images {
                    try enqueueCloudKitDeleteIfNeeded(recordType: .image, syncId: image.syncId, deletionTime: replacementTime, in: db)
                }
                for text in texts {
                    try enqueueCloudKitDeleteIfNeeded(recordType: .text, syncId: text.syncId, deletionTime: replacementTime, in: db)
                }
                try PostImage.deleteAll(db, ids: images.compactMap(\.id))
                try PostText.deleteAll(db, ids: texts.compactMap(\.id))
                try OnboardingLocalRecord.unmark(recordType: .image, syncIds: images.map(\.syncId), in: db)
                try OnboardingLocalRecord.unmark(recordType: .text, syncIds: texts.map(\.syncId), in: db)
                try promotePostGraphToUserContent(postId: postId, in: db)

                var text = PostText(postId: postId, content: content, order: 0)
                text.modificationTime = replacementTime
                try text.save(db)
                try enqueueCloudKitSaveIfNeeded(recordType: .text, syncId: text.syncId, modificationTime: text.modificationTime, in: db)
                try touchPostForCloudKit(postId: postId, modificationTime: replacementTime, in: db)
                deletedImages = images
            }
        } catch {
            print(error)
            return nil
        }
        DatabaseUpdateNotifier.shared.post(.DatabaseUpdated)
        return deletedImages
    }

    func replacePostBodyWithImage(
        postId: Int64,
        original: String,
        processed: String,
        rect: CGRect,
        orientation: Int
    ) -> [PostImage]? {
        var deletedImages: [PostImage] = []
        do {
            try dbWriter?.write { db in
                try requirePost(postId: postId, in: db)
                let images = try PostImage
                    .filter(Column(PostImage.CodingKeys.postId) == postId)
                    .fetchAll(db)
                let texts = try PostText
                    .filter(Column(PostText.CodingKeys.postId) == postId)
                    .fetchAll(db)
                // Same regression guard as replacePostBodyWithText.
                let maxBodyModificationTime = (images.map { $0.modificationTime ?? 0 } + texts.map { $0.modificationTime ?? 0 }).max()
                let replacementTime = try guardedDeletionTime(rowModificationTime: maxBodyModificationTime, in: db)
                for image in images {
                    try enqueueCloudKitDeleteIfNeeded(recordType: .image, syncId: image.syncId, deletionTime: replacementTime, in: db)
                }
                for text in texts {
                    try enqueueCloudKitDeleteIfNeeded(recordType: .text, syncId: text.syncId, deletionTime: replacementTime, in: db)
                }
                try PostImage.deleteAll(db, ids: images.compactMap(\.id))
                try PostText.deleteAll(db, ids: texts.compactMap(\.id))
                try OnboardingLocalRecord.unmark(recordType: .image, syncIds: images.map(\.syncId), in: db)
                try OnboardingLocalRecord.unmark(recordType: .text, syncIds: texts.map(\.syncId), in: db)
                try promotePostGraphToUserContent(postId: postId, in: db)

                var image = PostImage(
                    postId: postId,
                    original: original,
                    processed: processed,
                    orientation: Int64(orientation),
                    minX: Int64(rect.minX),
                    minY: Int64(rect.minY),
                    maxX: Int64(rect.maxX),
                    maxY: Int64(rect.maxY),
                    order: 0
                )
                image.modificationTime = replacementTime
                try image.save(db)
                try enqueueCloudKitSaveIfNeeded(recordType: .image, syncId: image.syncId, modificationTime: image.modificationTime, in: db)
                try touchPostForCloudKit(postId: postId, modificationTime: replacementTime, in: db)
                deletedImages = images
            }
        } catch {
            print(error)
            return nil
        }
        DatabaseUpdateNotifier.shared.post(.DatabaseUpdated)
        return deletedImages
    }
    
    /// Updates a post by mutating the freshly fetched row inside the write
    /// transaction. Callers express intent through `mutate` so columns they did
    /// not touch keep whatever value a concurrent writer (CloudKit pull) gave
    /// them — passing a stale in-memory snapshot would silently revert those
    /// fields and then win LWW with the bumped modification time.
    func updatePost(id: Int64, mutate: (inout Post) -> Void) -> Bool {
        var didChange = false
        do {
            _ = try dbWriter?.write{ db in
                guard var post = try Post.fetchOne(db, id: id) else {
                    throw AppDatabaseError.missingPost(id)
                }
                guard try post.updateChangesWithTimestamp(db, modify: mutate) else { return }
                try promotePostGraphToUserContent(postId: id, in: db)
                try enqueueCloudKitSaveIfNeeded(recordType: .post, syncId: post.syncId, modificationTime: post.modificationTime, in: db)
                didChange = true
            }
        }
        catch {
            print(error)
            return false
        }
        if didChange {
            DatabaseUpdateNotifier.shared.post(.DatabaseUpdated)
        }
        return true
    }
    
    func delete(post: Post) -> Bool {
        guard let postId = post.id else {
            return false
        }
        var didChangeDatabase = false
        do {
            _ = try dbWriter?.write{ db in
                let storedPost = try Post.fetchOne(db, id: postId)
                let images = try PostImage
                    .filter(Column(PostImage.CodingKeys.postId) == postId)
                    .fetchAll(db)
                let texts = try PostText
                    .filter(Column(PostText.CodingKeys.postId) == postId)
                    .fetchAll(db)
                let decorations = try PostDecoration
                    .filter(Column(PostDecoration.CodingKeys.postId) == postId)
                    .fetchAll(db)
                var graphModificationTime = storedPost?.modificationTime ?? 0
                for image in images {
                    graphModificationTime = max(graphModificationTime, image.modificationTime ?? 0)
                }
                for text in texts {
                    graphModificationTime = max(graphModificationTime, text.modificationTime ?? 0)
                }
                for decoration in decorations {
                    graphModificationTime = max(graphModificationTime, decoration.modificationTime ?? 0)
                }
                let deletionTime = try guardedDeletionTime(rowModificationTime: graphModificationTime, in: db)
                if let storedPost {
                    try enqueueCloudKitDeleteIfNeeded(recordType: .post, syncId: storedPost.syncId, deletionTime: deletionTime, in: db)
                }
                let cascadeName = storedPost.map { CloudKitRecordName.make(.post, syncId: $0.syncId) }
                let cascadeType: CloudKitAggregateType = cascadeName == nil ? .record : .postGraph
                for image in images {
                    try enqueueCloudKitDeleteIfNeeded(recordType: .image, syncId: image.syncId, deletionTime: deletionTime, aggregateType: cascadeType, aggregateName: cascadeName, in: db)
                }
                for text in texts {
                    try enqueueCloudKitDeleteIfNeeded(recordType: .text, syncId: text.syncId, deletionTime: deletionTime, aggregateType: cascadeType, aggregateName: cascadeName, in: db)
                }
                for decoration in decorations {
                    try enqueueCloudKitDeleteIfNeeded(recordType: .decoration, syncId: decoration.syncId, deletionTime: deletionTime, aggregateType: cascadeType, aggregateName: cascadeName, in: db)
                }
                try PostImage.deleteAll(db, ids: images.compactMap(\.id))
                try PostText.deleteAll(db, ids: texts.compactMap(\.id))
                try PostDecoration.deleteAll(db, ids: decorations.compactMap(\.id))
                try Post.deleteAll(db, ids: [postId])
                if let storedPost {
                    try OnboardingLocalRecord.unmark(recordType: .post, syncId: storedPost.syncId, in: db)
                }
                try OnboardingLocalRecord.unmark(recordType: .image, syncIds: images.map(\.syncId), in: db)
                try OnboardingLocalRecord.unmark(recordType: .text, syncIds: texts.map(\.syncId), in: db)
                try OnboardingLocalRecord.unmark(recordType: .decoration, syncIds: decorations.map(\.syncId), in: db)
                didChangeDatabase = storedPost != nil || !images.isEmpty || !texts.isEmpty || !decorations.isEmpty
            }
        }
        catch {
            print(error)
            return false
        }
        if didChangeDatabase {
            DatabaseUpdateNotifier.shared.post(.DatabaseUpdated)
        }
        return true
    }

    func deletePosts(by ids: [Int64]) -> Bool {
        guard !ids.isEmpty else { return true }
        do {
            _ = try dbWriter?.write{ db in
                var imageIds: [Int64] = []
                var textIds: [Int64] = []
                var decorationIds: [Int64] = []
                var deletedPosts: [Post] = []
                var deletedImages: [PostImage] = []
                var deletedTexts: [PostText] = []
                var deletedDecorations: [PostDecoration] = []
                for postId in ids {
                    let storedPost = try Post.fetchOne(db, id: postId)
                    let images = try PostImage
                        .filter(Column(PostImage.CodingKeys.postId) == postId)
                        .fetchAll(db)
                    let texts = try PostText
                        .filter(Column(PostText.CodingKeys.postId) == postId)
                        .fetchAll(db)
                    let decorations = try PostDecoration
                        .filter(Column(PostDecoration.CodingKeys.postId) == postId)
                        .fetchAll(db)
                    var graphModificationTime = storedPost?.modificationTime ?? 0
                    for image in images {
                        graphModificationTime = max(graphModificationTime, image.modificationTime ?? 0)
                    }
                    for text in texts {
                        graphModificationTime = max(graphModificationTime, text.modificationTime ?? 0)
                    }
                    for decoration in decorations {
                        graphModificationTime = max(graphModificationTime, decoration.modificationTime ?? 0)
                    }
                    let deletionTime = try guardedDeletionTime(rowModificationTime: graphModificationTime, in: db)
                    var cascadeName: String?
                    if let storedPost {
                        try enqueueCloudKitDeleteIfNeeded(recordType: .post, syncId: storedPost.syncId, deletionTime: deletionTime, in: db)
                        deletedPosts.append(storedPost)
                        cascadeName = CloudKitRecordName.make(.post, syncId: storedPost.syncId)
                    }
                    let cascadeType: CloudKitAggregateType = cascadeName == nil ? .record : .postGraph
                    for image in images {
                        try enqueueCloudKitDeleteIfNeeded(recordType: .image, syncId: image.syncId, deletionTime: deletionTime, aggregateType: cascadeType, aggregateName: cascadeName, in: db)
                    }
                    for text in texts {
                        try enqueueCloudKitDeleteIfNeeded(recordType: .text, syncId: text.syncId, deletionTime: deletionTime, aggregateType: cascadeType, aggregateName: cascadeName, in: db)
                    }
                    for decoration in decorations {
                        try enqueueCloudKitDeleteIfNeeded(recordType: .decoration, syncId: decoration.syncId, deletionTime: deletionTime, aggregateType: cascadeType, aggregateName: cascadeName, in: db)
                    }
                    deletedImages.append(contentsOf: images)
                    deletedTexts.append(contentsOf: texts)
                    deletedDecorations.append(contentsOf: decorations)
                    imageIds.append(contentsOf: images.compactMap(\.id))
                    textIds.append(contentsOf: texts.compactMap(\.id))
                    decorationIds.append(contentsOf: decorations.compactMap(\.id))
                }
                try PostImage.deleteAll(db, ids: imageIds)
                try PostText.deleteAll(db, ids: textIds)
                try PostDecoration.deleteAll(db, ids: decorationIds)
                try Post.deleteAll(db, ids: ids)
                for post in deletedPosts {
                    try OnboardingLocalRecord.unmark(recordType: .post, syncId: post.syncId, in: db)
                }
                try OnboardingLocalRecord.unmark(recordType: .image, syncIds: deletedImages.map(\.syncId), in: db)
                try OnboardingLocalRecord.unmark(recordType: .text, syncIds: deletedTexts.map(\.syncId), in: db)
                try OnboardingLocalRecord.unmark(recordType: .decoration, syncIds: deletedDecorations.map(\.syncId), in: db)
            }
        }
        catch {
            print(error)
            return false
        }
        DatabaseUpdateNotifier.shared.post(.DatabaseUpdated)
        return true
    }
}

extension AppDatabase {
    /// See `updatePost(id:mutate:)` for why updates go through a mutation
    /// closure instead of a caller-provided record.
    func updateImage(id: Int64, mutate: (inout PostImage) -> Void) -> Bool {
        return updateImageReturningReplacedProcessed(id: id, mutate: mutate).success
    }

    /// Returns the processed file that was actually replaced in the committed
    /// row. Editor saves can then clean up the correct old file even if the
    /// image changed remotely while the editor was open.
    func updateImageReturningReplacedProcessed(
        id: Int64,
        mutate: (inout PostImage) -> Void
    ) -> (success: Bool, replacedProcessed: String?) {
        var didChange = false
        var replacedProcessed: String?
        do {
            _ = try dbWriter?.write{ db in
                guard var image = try PostImage.fetchOne(db, id: id) else {
                    throw AppDatabaseError.missingImage(id)
                }
                let previousProcessed = image.processed
                var mutated = image
                mutate(&mutated)
                let originalPostId = image.postId
                try requirePost(postId: mutated.postId, in: db)
                guard try image.updateChangesWithTimestamp(db, modify: { $0 = mutated }) else { return }
                if previousProcessed != image.processed {
                    replacedProcessed = previousProcessed
                }
                try promotePostGraphToUserContent(postId: originalPostId, in: db)
                try enqueueCloudKitSaveIfNeeded(recordType: .image, syncId: image.syncId, modificationTime: image.modificationTime, in: db)
                try touchPostForCloudKit(postId: originalPostId, modificationTime: image.modificationTime, in: db)
                if mutated.postId != originalPostId {
                    try promotePostGraphToUserContent(postId: mutated.postId, in: db)
                    try touchPostForCloudKit(postId: mutated.postId, modificationTime: image.modificationTime, in: db)
                }
                didChange = true
            }
        }
        catch {
            print(error)
            return (false, nil)
        }
        if didChange {
            DatabaseUpdateNotifier.shared.post(.DatabaseUpdated)
        }
        return (true, replacedProcessed)
    }
    
    func delete(image: PostImage) -> Bool {
        guard let imageId = image.id else {
            return false
        }
        do {
            _ = try dbWriter?.write{ db in
                if let storedImage = try PostImage.fetchOne(db, id: imageId) {
                    let deletionTime = try guardedDeletionTime(rowModificationTime: storedImage.modificationTime, in: db)
                    try enqueueCloudKitDeleteIfNeeded(recordType: .image, syncId: storedImage.syncId, deletionTime: deletionTime, in: db)
                    try touchPostForCloudKit(postId: storedImage.postId, modificationTime: deletionTime, in: db)
                    try OnboardingLocalRecord.unmark(recordType: .image, syncId: storedImage.syncId, in: db)
                    try PostImage.deleteAll(db, ids: [imageId])
                } else {
                    try PostImage.deleteAll(db, ids: [imageId])
                }
            }
        }
        catch {
            print(error)
            return false
        }
        DatabaseUpdateNotifier.shared.post(.DatabaseUpdated)
        return true
    }
    
    func delete(images: [PostImage]) -> Bool {
        let imageIds = images.compactMap{ $0.id }
        guard imageIds.count > 0 else {
            return false
        }
        do {
            _ = try dbWriter?.write{ db in
                let storedImages = try PostImage
                    .filter(ids: imageIds)
                    .fetchAll(db)
                var touchTimeByPostId: [Int64: Int64] = [:]
                for image in storedImages {
                    let deletionTime = try guardedDeletionTime(rowModificationTime: image.modificationTime, in: db)
                    try enqueueCloudKitDeleteIfNeeded(recordType: .image, syncId: image.syncId, deletionTime: deletionTime, in: db)
                    touchTimeByPostId[image.postId] = max(touchTimeByPostId[image.postId] ?? 0, deletionTime)
                }
                for (postId, touchTime) in touchTimeByPostId {
                    try touchPostForCloudKit(postId: postId, modificationTime: touchTime, in: db)
                }
                try PostImage.deleteAll(db, ids: imageIds)
                try OnboardingLocalRecord.unmark(recordType: .image, syncIds: storedImages.map(\.syncId), in: db)
            }
        }
        catch {
            print(error)
            return false
        }
        DatabaseUpdateNotifier.shared.post(.DatabaseUpdated)
        return true
    }
}

extension AppDatabase {
    /// See `updatePost(id:mutate:)` for why updates go through a mutation
    /// closure instead of a caller-provided record.
    func updateText(id: Int64, mutate: (inout PostText) -> Void) -> Bool {
        var didChange = false
        do {
            _ = try dbWriter?.write{ db in
                guard var text = try PostText.fetchOne(db, id: id) else {
                    throw AppDatabaseError.missingText(id)
                }
                var mutated = text
                mutate(&mutated)
                let originalPostId = text.postId
                try requirePost(postId: mutated.postId, in: db)
                guard try text.updateChangesWithTimestamp(db, modify: { $0 = mutated }) else { return }
                try promotePostGraphToUserContent(postId: originalPostId, in: db)
                try enqueueCloudKitSaveIfNeeded(recordType: .text, syncId: text.syncId, modificationTime: text.modificationTime, in: db)
                try touchPostForCloudKit(postId: originalPostId, modificationTime: text.modificationTime, in: db)
                if mutated.postId != originalPostId {
                    try promotePostGraphToUserContent(postId: mutated.postId, in: db)
                    try touchPostForCloudKit(postId: mutated.postId, modificationTime: text.modificationTime, in: db)
                }
                didChange = true
            }
        }
        catch {
            print(error)
            return false
        }
        if didChange {
            DatabaseUpdateNotifier.shared.post(.DatabaseUpdated)
        }
        return true
    }
    
    func delete(text: PostText) -> Bool {
        guard let textId = text.id else {
            return false
        }
        do {
            _ = try dbWriter?.write{ db in
                if let storedText = try PostText.fetchOne(db, id: textId) {
                    let deletionTime = try guardedDeletionTime(rowModificationTime: storedText.modificationTime, in: db)
                    try enqueueCloudKitDeleteIfNeeded(recordType: .text, syncId: storedText.syncId, deletionTime: deletionTime, in: db)
                    try touchPostForCloudKit(postId: storedText.postId, modificationTime: deletionTime, in: db)
                    try OnboardingLocalRecord.unmark(recordType: .text, syncId: storedText.syncId, in: db)
                    try PostText.deleteAll(db, ids: [textId])
                } else {
                    try PostText.deleteAll(db, ids: [textId])
                }
            }
        }
        catch {
            print(error)
            return false
        }
        DatabaseUpdateNotifier.shared.post(.DatabaseUpdated)
        return true
    }
    
    func delete(texts: [PostText]) -> Bool {
        let textIds = texts.compactMap{ $0.id }
        guard textIds.count > 0 else {
            return false
        }
        do {
            _ = try dbWriter?.write{ db in
                let storedTexts = try PostText
                    .filter(ids: textIds)
                    .fetchAll(db)
                var touchTimeByPostId: [Int64: Int64] = [:]
                for text in storedTexts {
                    let deletionTime = try guardedDeletionTime(rowModificationTime: text.modificationTime, in: db)
                    try enqueueCloudKitDeleteIfNeeded(recordType: .text, syncId: text.syncId, deletionTime: deletionTime, in: db)
                    touchTimeByPostId[text.postId] = max(touchTimeByPostId[text.postId] ?? 0, deletionTime)
                }
                for (postId, touchTime) in touchTimeByPostId {
                    try touchPostForCloudKit(postId: postId, modificationTime: touchTime, in: db)
                }
                try PostText.deleteAll(db, ids: textIds)
                try OnboardingLocalRecord.unmark(recordType: .text, syncIds: storedTexts.map(\.syncId), in: db)
            }
        }
        catch {
            print(error)
            return false
        }
        DatabaseUpdateNotifier.shared.post(.DatabaseUpdated)
        return true
    }
}

extension AppDatabase {
    public func update(postIds: [Int64], isPinned: Bool, promotesLocalOnboarding: Bool = true) -> Bool {
        guard !postIds.isEmpty else { return true }
        var didChangeDatabase = false
        do {
            _ = try dbWriter?.write{ db in
                // Compute the order inside the transaction: a concurrent writer
                // (e.g. a CloudKit pull) may insert posts between a read-only
                // pre-computation and this write.
                var nextOrder = try nextPostOrder(isPinned: isPinned, in: db)
                for id in postIds {
                    guard var post = try Post.fetchOne(db, id: id) else {
                        continue
                    }
                    // Skip posts already in the target state: rewriting them would
                    // bump modification_time and order on every pass and flood the
                    // CloudKit outbox with no-op saves.
                    guard post.isPinned != isPinned else {
                        continue
                    }
                    post.isPinned = isPinned
                    post.order = nextOrder
                    nextOrder += 1
                    if promotesLocalOnboarding, let id = post.id {
                        try promotePostGraphToUserContent(postId: id, in: db)
                    }
                    try post.updateWithTimestamp(db)
                    try enqueueCloudKitSaveIfNeeded(recordType: .post, syncId: post.syncId, modificationTime: post.modificationTime, in: db)
                    didChangeDatabase = true
                }
            }
        }
        catch {
            print(error)
            return false
        }
        if didChangeDatabase {
            DatabaseUpdateNotifier.shared.post(.DatabaseUpdated)
        }
        return true
    }

    public func updatePostPinnedState(postId: Int64, isPinned: Bool, enforcesSinglePinnedPost: Bool) -> Bool {
        do {
            _ = try dbWriter?.write { db in
                guard var post = try Post.fetchOne(db, id: postId) else {
                    throw AppDatabaseError.missingPost(postId)
                }
                if isPinned, enforcesSinglePinnedPost {
                    try unpinAllPinnedPosts(in: db, excludingPostId: postId, promotesLocalOnboarding: false)
                }
                try promotePostGraphToUserContent(postId: postId, in: db)
                post.isPinned = isPinned
                post.order = isPinned && enforcesSinglePinnedPost ? 0 : try nextPostOrder(isPinned: isPinned, in: db)
                try post.updateWithTimestamp(db)
                try enqueueCloudKitSaveIfNeeded(recordType: .post, syncId: post.syncId, modificationTime: post.modificationTime, in: db)
            }
        } catch {
            print(error)
            return false
        }
        DatabaseUpdateNotifier.shared.post(.DatabaseUpdated)
        return true
    }
    
    /// Batch pin/order placement used by drag-to-reorder. Rows are fetched
    /// fresh inside the transaction; only posts whose placement actually
    /// differs are written and enqueued.
    public func updatePostPlacements(_ placements: [(postId: Int64, isPinned: Bool, order: Int64)]) -> Bool {
        var didChange = false
        do {
            _ = try dbWriter?.write{ db in
                for placement in placements {
                    guard var post = try Post.fetchOne(db, id: placement.postId) else { continue }
                    let changed = try post.updateChangesWithTimestamp(db) {
                        $0.isPinned = placement.isPinned
                        $0.order = placement.order
                    }
                    guard changed else { continue }
                    try promotePostGraphToUserContent(postId: placement.postId, in: db)
                    try enqueueCloudKitSaveIfNeeded(recordType: .post, syncId: post.syncId, modificationTime: post.modificationTime, in: db)
                    didChange = true
                }
            }
        }
        catch {
            print(error)
            return false
        }
        if didChange {
            DatabaseUpdateNotifier.shared.post(.DatabaseUpdated)
        }
        return true
    }
}

extension AppDatabase {
    func add(style: PostStyle) -> PostStyle? {
        guard style.id == nil else {
            return nil
        }
        var saveStyle = style
        do {
            try dbWriter?.write{ db in
                try saveStyle.save(db)
                try enqueueCloudKitSaveIfNeeded(recordType: .style, syncId: saveStyle.syncId, modificationTime: saveStyle.modificationTime, in: db)
            }
        }
        catch {
            print(error)
            return nil
        }
        DatabaseUpdateNotifier.shared.post(.DatabaseUpdated)
        DatabaseUpdateNotifier.shared.post(.DatabaseStyleUpdated)
        return saveStyle
    }
    
    /// See `updatePost(id:mutate:)` for why updates go through a mutation
    /// closure instead of a caller-provided record.
    func updateStyle(id: Int64, mutate: (inout PostStyle) -> Void) -> Bool {
        var didChange = false
        do {
            _ = try dbWriter?.write{ db in
                guard var style = try PostStyle.fetchOne(db, id: id) else {
                    throw AppDatabaseError.missingStyle(id)
                }
                guard try style.updateChangesWithTimestamp(db, modify: mutate) else { return }
                try promoteStyleToUserContent(styleId: id, in: db)
                try enqueueCloudKitSaveIfNeeded(recordType: .style, syncId: style.syncId, modificationTime: style.modificationTime, in: db)
                didChange = true
            }
        }
        catch {
            print(error)
            return false
        }
        if didChange {
            DatabaseUpdateNotifier.shared.post(.DatabaseUpdated)
            DatabaseUpdateNotifier.shared.post(.DatabaseStyleUpdated)
        }
        return true
    }
    
    func delete(style: PostStyle) -> Bool {
        guard let styleId = style.id else {
            return false
        }
        do {
            _ = try dbWriter?.write{ db in
                let storedStyle = try PostStyle.fetchOne(db, id: styleId)
                // Ordered by syncId, not row id: every device must resolve the
                // SAME fallback for the same library, or the receivers' local
                // adoptions (stamped at the tombstone's deletionTime) diverge
                // whenever the deleter's authoritative push is lost.
                let fallbackStyle = try PostStyle
                    .filter(PostStyle.Columns.id != styleId)
                    .order(Column(PostStyle.CodingKeys.syncId).asc)
                    .fetchOne(db)
                let decorations = try PostDecoration
                    .filter(Column(PostDecoration.CodingKeys.styleId) == styleId)
                    .fetchAll(db)
                var graphModificationTime = storedStyle?.modificationTime ?? 0
                for decoration in decorations {
                    graphModificationTime = max(graphModificationTime, decoration.modificationTime ?? 0)
                }
                let deletionTime = try guardedDeletionTime(rowModificationTime: graphModificationTime, in: db)
                if let storedStyle {
                    try enqueueCloudKitDeleteIfNeeded(recordType: .style, syncId: storedStyle.syncId, deletionTime: deletionTime, in: db)
                }
                let cascadeName = storedStyle.map { CloudKitRecordName.make(.style, syncId: $0.syncId) }
                let cascadeType: CloudKitAggregateType = cascadeName == nil ? .record : .styleGraph
                for decoration in decorations {
                    try enqueueCloudKitDeleteIfNeeded(recordType: .decoration, syncId: decoration.syncId, deletionTime: deletionTime, aggregateType: cascadeType, aggregateName: cascadeName, in: db)
                    // Cascading a decoration delete changes the post graph, same
                    // as delete(decoration:) — keep the aggregate version in step.
                    try touchPostForCloudKit(postId: decoration.postId, modificationTime: deletionTime, in: db)
                }
                try PostDecoration.deleteAll(db, ids: decorations.compactMap(\.id))
                try PostStyle.deleteAll(db, ids: [styleId])
                if let storedStyle {
                    let tracksCloudKit = tracksLocalCloudKitChanges()
                    // deletionTime + 1: receivers applying the tombstone adopt
                    // their own syncId-ordered fallbacks locally, stamped at
                    // deletionTime, WITHOUT pushing. Only this device — the
                    // deleter — pushes a replacement, and it must beat those
                    // local stamps or every device keeps its own divergent
                    // fallback forever (the apply guard is strictly newer).
                    if try DefaultStyle.replaceDeletedStyleIfNeeded(
                        deletedStyle: storedStyle,
                        fallbackStyle: fallbackStyle,
                        modificationTime: deletionTime + 1,
                        updatesCloudKitSetting: tracksCloudKit,
                        in: db
                    ), tracksCloudKit {
                        try CloudKitOutboxEntry.enqueueSetting(
                            modificationTime: deletionTime + 1,
                            in: db
                        )
                    }
                    try OnboardingLocalRecord.unmark(recordType: .style, syncId: storedStyle.syncId, in: db)
                }
                try OnboardingLocalRecord.unmark(recordType: .decoration, syncIds: decorations.map(\.syncId), in: db)
            }
        }
        catch {
            print(error)
            return false
        }
        DatabaseUpdateNotifier.shared.post(.DatabaseUpdated)
        DatabaseUpdateNotifier.shared.post(.DatabaseStyleUpdated)
        return true
    }
}

extension AppDatabase {
    func add(decoration: PostDecoration) -> Bool {
        guard decoration.id == nil else {
            return false
        }
        do {
            try dbWriter?.write{ db in
                var saveDecoration = decoration
                try requirePost(postId: saveDecoration.postId, in: db)
                try requireStyle(styleId: saveDecoration.styleId, in: db)
                try promotePostGraphToUserContent(postId: saveDecoration.postId, in: db)
                try promoteStyleToUserContent(styleId: saveDecoration.styleId, in: db)
                try deleteConflictingDecorations(postId: saveDecoration.postId, excludingId: nil, in: db)
                try saveDecoration.save(db)
                try enqueueCloudKitSaveIfNeeded(recordType: .decoration, syncId: saveDecoration.syncId, modificationTime: saveDecoration.modificationTime, in: db)
                try touchPostForCloudKit(postId: saveDecoration.postId, modificationTime: saveDecoration.modificationTime, in: db)
                try touchStyleForCloudKit(styleId: saveDecoration.styleId, modificationTime: saveDecoration.modificationTime, in: db)
            }
        }
        catch {
            print(error)
            return false
        }
        DatabaseUpdateNotifier.shared.post(.DatabaseUpdated)
        DatabaseUpdateNotifier.shared.post(.DatabaseStyleUpdated)
        return true
    }
    
    /// See `updatePost(id:mutate:)` for why updates go through a mutation
    /// closure instead of a caller-provided record.
    func updateDecoration(id: Int64, mutate: (inout PostDecoration) -> Void) -> Bool {
        var didChange = false
        do {
            _ = try dbWriter?.write{ db in
                guard var decoration = try PostDecoration.fetchOne(db, id: id) else {
                    throw AppDatabaseError.missingDecoration(id)
                }
                var mutated = decoration
                mutate(&mutated)
                let originalPostId = decoration.postId
                let originalStyleId = decoration.styleId
                try requirePost(postId: mutated.postId, in: db)
                try requireStyle(styleId: mutated.styleId, in: db)
                // Clear whatever decoration already occupies the target post BEFORE
                // the UPDATE trips over the unique index on decoration.post_id.
                try deleteConflictingDecorations(postId: mutated.postId, excludingId: id, in: db)
                guard try decoration.updateChangesWithTimestamp(db, modify: { $0 = mutated }) else { return }
                try promotePostGraphToUserContent(postId: originalPostId, in: db)
                try promoteStyleToUserContent(styleId: originalStyleId, in: db)
                try enqueueCloudKitSaveIfNeeded(recordType: .decoration, syncId: decoration.syncId, modificationTime: decoration.modificationTime, in: db)
                try touchPostForCloudKit(postId: originalPostId, modificationTime: decoration.modificationTime, in: db)
                try touchStyleForCloudKit(styleId: originalStyleId, modificationTime: decoration.modificationTime, in: db)
                if mutated.postId != originalPostId {
                    try promotePostGraphToUserContent(postId: mutated.postId, in: db)
                    try touchPostForCloudKit(postId: mutated.postId, modificationTime: decoration.modificationTime, in: db)
                }
                if mutated.styleId != originalStyleId {
                    try promoteStyleToUserContent(styleId: mutated.styleId, in: db)
                    try touchStyleForCloudKit(styleId: mutated.styleId, modificationTime: decoration.modificationTime, in: db)
                }
                didChange = true
            }
        }
        catch {
            print(error)
            return false
        }
        if didChange {
            DatabaseUpdateNotifier.shared.post(.DatabaseUpdated)
            DatabaseUpdateNotifier.shared.post(.DatabaseStyleUpdated)
        }
        return true
    }
    
    func delete(decoration: PostDecoration) -> Bool {
        guard let decorationId = decoration.id else {
            return false
        }
        do {
            _ = try dbWriter?.write{ db in
                if let storedDecoration = try PostDecoration.fetchOne(db, id: decorationId) {
                    let deletionTime = try guardedDeletionTime(rowModificationTime: storedDecoration.modificationTime, in: db)
                    try enqueueCloudKitDeleteIfNeeded(recordType: .decoration, syncId: storedDecoration.syncId, deletionTime: deletionTime, in: db)
                    try touchPostForCloudKit(postId: storedDecoration.postId, modificationTime: deletionTime, in: db)
                    try touchStyleForCloudKit(styleId: storedDecoration.styleId, modificationTime: deletionTime, in: db)
                    try OnboardingLocalRecord.unmark(recordType: .decoration, syncId: storedDecoration.syncId, in: db)
                    try PostDecoration.deleteAll(db, ids: [decorationId])
                } else {
                    try PostDecoration.deleteAll(db, ids: [decorationId])
                }
            }
        }
        catch {
            print(error)
            return false
        }
        DatabaseUpdateNotifier.shared.post(.DatabaseUpdated)
        DatabaseUpdateNotifier.shared.post(.DatabaseStyleUpdated)
        return true
    }
}

private extension AppDatabase {
    func requirePost(postId: Int64, in db: Database) throws {
        guard try Post.fetchOne(db, id: postId) != nil else {
            throw AppDatabaseError.missingPost(postId)
        }
    }

    func requireStyle(styleId: Int64, in db: Database) throws {
        guard try PostStyle.fetchOne(db, id: styleId) != nil else {
            throw AppDatabaseError.missingStyle(styleId)
        }
    }

    func tracksLocalCloudKitChanges() -> Bool {
        CloudKitSync.current == .enable || CloudKitSync.pendingRemoteReset
    }

    func nextPostOrder(isPinned: Bool, in db: Database) throws -> Int64 {
        let maxOrder = try Int64.fetchOne(
            db,
            sql: #"SELECT MAX("order") FROM post WHERE is_pinned = ?"#,
            arguments: [isPinned]
        )
        return (maxOrder ?? -1) + 1
    }

    func unpinAllPinnedPosts(in db: Database, excludingPostId: Int64? = nil, promotesLocalOnboarding: Bool = true) throws {
        var request = Post
            .filter(Post.Columns.isPinned == true)
        if let excludingPostId {
            request = request.filter(Column(Post.CodingKeys.id) != excludingPostId)
        }
        let pinnedPosts = try request
            .order(Post.Columns.order.asc)
            .fetchAll(db)
        guard !pinnedPosts.isEmpty else { return }
        let firstOrder = try nextPostOrder(isPinned: false, in: db)
        for (index, pinnedPost) in pinnedPosts.enumerated() {
            var post = pinnedPost
            post.isPinned = false
            post.order = firstOrder + Int64(index)
            if promotesLocalOnboarding, let postId = post.id {
                try promotePostGraphToUserContent(postId: postId, in: db)
            }
            try post.updateWithTimestamp(db)
            try enqueueCloudKitSaveIfNeeded(recordType: .post, syncId: post.syncId, modificationTime: post.modificationTime, in: db)
        }
    }

    /// `deletionTime` must carry the same regression guard the save path gets
    /// from `nextModificationTime` — `guardedDeletionTime` below. The raw
    /// transaction clock loses the LWW arbitration whenever the row's
    /// modification time came from a clock-ahead peer, and the deliberate
    /// local delete would be undone on every device (the send path would even
    /// abort the cascade and restore the data on THIS device).
    @discardableResult
    func enqueueCloudKitDeleteIfNeeded(
        recordType: CloudKitRecordType,
        syncId: String,
        deletionTime: Int64? = nil,
        aggregateType: CloudKitAggregateType = .record,
        aggregateName: String? = nil,
        in db: Database
    ) throws -> Bool {
        guard try !OnboardingLocalRecord.isMarked(recordType: recordType, syncId: syncId, in: db) else { return false }
        if tracksLocalCloudKitChanges() {
            try CloudKitOutboxEntry.enqueueDelete(
                recordType: recordType,
                syncId: syncId,
                deletionTime: deletionTime,
                aggregateType: aggregateType,
                aggregateName: aggregateName,
                in: db
            )
            return true
        } else if CloudKitSync.remoteDataMayExist {
            // Sync is off but a previous session synced this record. Stash a real
            // tombstone with the actual deletion time so the next re-enable's
            // reconciliation can ship the delete with a timestamp that wins against
            // server edits made between disable and now (rather than the stale
            // lastSyncedVersion+1 fallback).
            let recordName = CloudKitRecordName.make(recordType, syncId: syncId)
            try CloudKitLocalTombstone.store(
                recordType: recordType,
                recordName: recordName,
                deletionTime: deletionTime ?? db.transactionDate.nanoSecondSince1970,
                aggregateType: aggregateType,
                aggregateName: aggregateName,
                in: db
            )
            return true
        }
        return false
    }

    /// A delete must beat the row(s) it deletes: their modification times may
    /// come from a clock-ahead peer, so the transaction clock alone can lose
    /// against the very data the user just deleted. Cascades pass the whole
    /// graph's maximum so every member carries one winning timestamp.
    /// Note: a concurrent edit on another clock-behind device anchors its
    /// save to the same `row + 1` (nextModificationTime), manufacturing a tie
    /// — which resolves to the delete. Deletes win ties by design.
    func guardedDeletionTime(rowModificationTime: Int64?, in db: Database) throws -> Int64 {
        max(try db.transactionDate.nanoSecondSince1970, (rowModificationTime ?? 0) + 1)
    }

    func enqueueCloudKitSaveIfNeeded(recordType: CloudKitRecordType, syncId: String, modificationTime: Int64?, in db: Database) throws {
        guard tracksLocalCloudKitChanges() else { return }
        if try OnboardingLocalRecord.isMarked(recordType: recordType, syncId: syncId, in: db) {
            try CloudKitOutboxEntry.clear(recordName: CloudKitRecordName.make(recordType, syncId: syncId), in: db)
            return
        }
        if recordType == .post,
           let post = try Post.filter(Column(Post.CodingKeys.syncId) == syncId).fetchOne(db),
           let postId = post.id {
            try CloudKitOutboxEntry.enqueuePostGraphSave(postId: postId, modificationTime: modificationTime, in: db)
            return
        }
        if recordType == .style,
           let style = try PostStyle.filter(Column(PostStyle.CodingKeys.syncId) == syncId).fetchOne(db),
           let styleId = style.id {
            try CloudKitOutboxEntry.enqueueStyleGraphSave(styleId: styleId, modificationTime: modificationTime, in: db)
            return
        }
        try CloudKitOutboxEntry.enqueueSave(recordType: recordType, syncId: syncId, modificationTime: modificationTime, in: db)
    }

    func promotePostGraphToUserContent(postId: Int64, in db: Database) throws {
        try OnboardingManager.shared.promotePostGraphToUserContent(postId: postId, in: db)
    }

    func promoteStyleToUserContent(styleId: Int64, in db: Database) throws {
        try OnboardingManager.shared.promoteStyleToUserContent(styleId: styleId, in: db)
    }

    func touchPostForCloudKit(postId: Int64, modificationTime: Int64?, in db: Database) throws {
        guard tracksLocalCloudKitChanges() else { return }
        try CloudKitOutboxEntry.enqueuePostGraphSave(postId: postId, modificationTime: modificationTime, in: db)
    }

    func touchStyleForCloudKit(styleId: Int64, modificationTime: Int64?, in db: Database) throws {
        guard tracksLocalCloudKitChanges() else { return }
        try CloudKitOutboxEntry.enqueueStyleGraphSave(styleId: styleId, modificationTime: modificationTime, in: db)
    }

    func deleteConflictingDecorations(postId: Int64, excludingId: Int64?, in db: Database) throws {
        var request = PostDecoration
            .filter(Column(PostDecoration.CodingKeys.postId) == postId)
        if let excludingId {
            request = request.filter(Column(PostDecoration.CodingKeys.id) != excludingId)
        }
        let decorations = try request.fetchAll(db)
        for decoration in decorations {
            let deletionTime = try guardedDeletionTime(rowModificationTime: decoration.modificationTime, in: db)
            try enqueueCloudKitDeleteIfNeeded(recordType: .decoration, syncId: decoration.syncId, deletionTime: deletionTime, in: db)
            try touchStyleForCloudKit(styleId: decoration.styleId, modificationTime: deletionTime, in: db)
        }
        try PostDecoration.deleteAll(db, ids: decorations.compactMap(\.id))
        try OnboardingLocalRecord.unmark(recordType: .decoration, syncIds: decorations.map(\.syncId), in: db)
    }

}

extension AppDatabase {
    func enqueueDefaultStyleCloudKitSync(styleId: Int64?, syncId: String?, modificationTime: Int64) throws {
        guard tracksLocalCloudKitChanges() else { return }
        try dbWriter?.write { db in
            if let styleId,
               try PostStyle.fetchOne(db, id: styleId) != nil {
                try promoteStyleToUserContent(styleId: styleId, in: db)
                try touchStyleForCloudKit(styleId: styleId, modificationTime: modificationTime, in: db)
            }
            try CloudKitSettingRecord.saveDefaultStyle(syncId: syncId, modificationTime: modificationTime, in: db)
            try CloudKitOutboxEntry.enqueueSetting(modificationTime: modificationTime, in: db)
        }
    }

    public func reset() -> Bool {
        let shouldRebuildCloudKit = CloudKitSync.current == .enable
        let hadPendingRemoteReset = CloudKitSync.pendingRemoteReset
        do {
            guard let dbWriter else { return false }
            if shouldRebuildCloudKit {
                CloudKitRecordSyncManager.shared.cancelSyncForLocalReset()
                // Before the destructive write: dying between the commit and this
                // flag would otherwise let the next full fetch quietly restore the
                // cloud copy of everything the user just reset.
                CloudKitSync.setPendingRemoteReset(true)
            }
            try dbWriter.write { db in
                try PostImage.deleteAll(db)
                try PostText.deleteAll(db)
                try PostDecoration.deleteAll(db)
                try Post.deleteAll(db)
                try PostStyle.deleteAll(db)
                try OnboardingLocalRecord.deleteAll(db)
                try CloudKitOutboxEntry.deleteAll(db)
                try CloudKitRecordMetadata.deleteAll(db)
                try CloudKitLocalTombstone.deleteAll(db)
                try CloudKitSyncState.clearSyncEngineStateSerialization(in: db)
                try CloudKitSyncState.clearBootstrapSuppression(in: db)
                try CloudKitSyncState.clearLocalRecordPreservation(in: db)
                try CloudKitSyncState.clearZoneDiscontinuityProbe(in: db)
                // A pre-reset cascade-abort recovery intent has nothing left to
                // restore; leaving it would force a pointless engine-state
                // reset and full re-download right after the rebuild.
                try CloudKitSyncState.clearPendingFullFetchRecovery(in: db)
                try CloudKitSettingRecord.deleteAll(db)
                try db.execute(
                    sql: """
                        DELETE FROM sqlite_sequence
                        WHERE name IN (
                            'post',
                            'text',
                            'image',
                            'style',
                            'decoration',
                            'local_onboarding_record'
                        )
                    """
                )
            }
        } catch {
            print(error)
            if shouldRebuildCloudKit && !hadPendingRemoteReset {
                CloudKitSync.setPendingRemoteReset(false)
            }
            return false
        }
        
        OnboardingManager.shared.requestOnboardingSeed()
        DatabaseUpdateNotifier.shared.post(.DatabaseUpdated)
        return true
    }
}

/// Coalesces change notifications onto the next main-runloop tick: one user
/// action can hit several write APIs (an editor save touches text, image,
/// decoration, and post), and posting from each call made every main-thread
/// observer rebuild its UI once per write. Also normalizes posts from
/// background callers (e.g. reset on a utility queue) onto the main thread.
final class DatabaseUpdateNotifier {
    static let shared = DatabaseUpdateNotifier()

    // Main-thread confined.
    private var pendingNames: [Notification.Name] = []

    func post(_ name: Notification.Name) {
        if Thread.isMainThread {
            enqueue(name)
        } else {
            DispatchQueue.main.async {
                self.enqueue(name)
            }
        }
    }

    private func enqueue(_ name: Notification.Name) {
        if pendingNames.isEmpty {
            DispatchQueue.main.async {
                self.flush()
            }
        }
        if !pendingNames.contains(name) {
            pendingNames.append(name)
        }
    }

    private func flush() {
        let names = pendingNames
        pendingNames = []
        for name in names {
            NotificationCenter.default.post(name: name, object: nil)
        }
    }
}

extension AppDatabase {
    /// Provides a read-only access to the database
    var reader: DatabaseReader? {
        dbWriter
    }
}
