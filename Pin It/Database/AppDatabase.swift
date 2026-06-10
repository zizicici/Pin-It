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
                let isPinned: Bool = row["is_pinned"]
                let nextOrder = nextOrderByPinnedState[isPinned] ?? 0
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
                        isPinned,
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
                nextOrderByPinnedState[isPinned] = nextOrder + 1
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

        return migrator
    }
    
    public func disconnect() {
        self.dbWriter = nil
    }
    
    public func reconnect() {
        do {
            let databasePool = try AppDatabase.generateDatabasePool()
            try migrator.migrate(databasePool)
            self.dbWriter = databasePool
        } catch {
            print(error)
        }
    }
}

extension AppDatabase {
    func add(post: Post) -> Post? {
        guard post.id == nil else {
            return nil
        }
        var result: Post?
        do {
            try dbWriter?.write{ db in
                var savePost = post
                try savePost.save(db)
                try enqueueCloudKitSaveIfNeeded(recordType: .post, syncId: savePost.syncId, modificationTime: savePost.modificationTime, in: db)
                result = savePost
            }
        }
        catch {
            print(error)
            return nil
        }
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
        return result
    }

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
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
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
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
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
                let modificationTime = try db.transactionDate.nanoSecondSince1970
                for image in images {
                    try enqueueCloudKitDeleteIfNeeded(recordType: .image, syncId: image.syncId, in: db)
                }
                for text in texts {
                    try enqueueCloudKitDeleteIfNeeded(recordType: .text, syncId: text.syncId, in: db)
                }
                try PostImage.deleteAll(db, ids: images.compactMap(\.id))
                try PostText.deleteAll(db, ids: texts.compactMap(\.id))
                try OnboardingLocalRecord.unmark(recordType: .image, syncIds: images.map(\.syncId), in: db)
                try OnboardingLocalRecord.unmark(recordType: .text, syncIds: texts.map(\.syncId), in: db)
                try promotePostGraphToUserContent(postId: postId, in: db)

                var text = PostText(postId: postId, content: content, order: 0)
                try text.save(db)
                try enqueueCloudKitSaveIfNeeded(recordType: .text, syncId: text.syncId, modificationTime: text.modificationTime, in: db)
                try touchPostForCloudKit(postId: postId, modificationTime: max(text.modificationTime ?? 0, modificationTime), in: db)
                deletedImages = images
            }
        } catch {
            print(error)
            return nil
        }
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
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
                let modificationTime = try db.transactionDate.nanoSecondSince1970
                for image in images {
                    try enqueueCloudKitDeleteIfNeeded(recordType: .image, syncId: image.syncId, in: db)
                }
                for text in texts {
                    try enqueueCloudKitDeleteIfNeeded(recordType: .text, syncId: text.syncId, in: db)
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
                try image.save(db)
                try enqueueCloudKitSaveIfNeeded(recordType: .image, syncId: image.syncId, modificationTime: image.modificationTime, in: db)
                try touchPostForCloudKit(postId: postId, modificationTime: max(image.modificationTime ?? 0, modificationTime), in: db)
                deletedImages = images
            }
        } catch {
            print(error)
            return nil
        }
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
        return deletedImages
    }
    
    func update(post: Post) -> Bool {
        guard post.id != nil else {
            return false
        }
        do {
            _ = try dbWriter?.write{ db in
                var savePost = post
                if let postId = savePost.id {
                    try promotePostGraphToUserContent(postId: postId, in: db)
                }
                try savePost.updateWithTimestamp(db)
                try enqueueCloudKitSaveIfNeeded(recordType: .post, syncId: savePost.syncId, modificationTime: savePost.modificationTime, in: db)
            }
        }
        catch {
            print(error)
            return false
        }
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
        return true
    }
    
    func delete(post: Post) -> Bool {
        guard let postId = post.id else {
            return false
        }
        do {
            _ = try dbWriter?.write{ db in
                let storedPost = try Post.fetchOne(db, id: postId)
                if let storedPost {
                    try enqueueCloudKitDeleteIfNeeded(recordType: .post, syncId: storedPost.syncId, in: db)
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
                for image in images {
                    try enqueueCloudKitDeleteIfNeeded(recordType: .image, syncId: image.syncId, in: db)
                }
                for text in texts {
                    try enqueueCloudKitDeleteIfNeeded(recordType: .text, syncId: text.syncId, in: db)
                }
                for decoration in decorations {
                    try enqueueCloudKitDeleteIfNeeded(recordType: .decoration, syncId: decoration.syncId, in: db)
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
            }
        }
        catch {
            print(error)
            return false
        }
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
        return true
    }
    
    func deletePosts(by ids: [Int64]) -> Bool {
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
                    if let storedPost = try Post.fetchOne(db, id: postId) {
                        try enqueueCloudKitDeleteIfNeeded(recordType: .post, syncId: storedPost.syncId, in: db)
                        deletedPosts.append(storedPost)
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
                    for image in images {
                        try enqueueCloudKitDeleteIfNeeded(recordType: .image, syncId: image.syncId, in: db)
                    }
                    for text in texts {
                        try enqueueCloudKitDeleteIfNeeded(recordType: .text, syncId: text.syncId, in: db)
                    }
                    for decoration in decorations {
                        try enqueueCloudKitDeleteIfNeeded(recordType: .decoration, syncId: decoration.syncId, in: db)
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
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
        return true
    }
}

extension AppDatabase {
    func add(image: PostImage) -> Bool {
        guard image.id == nil else {
            return false
        }
        do {
            try dbWriter?.write{ db in
                var saveImage = image
                try requirePost(postId: saveImage.postId, in: db)
                try promotePostGraphToUserContent(postId: saveImage.postId, in: db)
                try saveImage.save(db)
                try enqueueCloudKitSaveIfNeeded(recordType: .image, syncId: saveImage.syncId, modificationTime: saveImage.modificationTime, in: db)
                try touchPostForCloudKit(postId: saveImage.postId, modificationTime: saveImage.modificationTime, in: db)
            }
        }
        catch {
            print(error)
            return false
        }
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
        return true
    }
    
    func update(image: PostImage) -> Bool {
        guard let imageId = image.id else {
            return false
        }
        do {
            _ = try dbWriter?.write{ db in
                var saveImage = image
                guard let storedImage = try PostImage.fetchOne(db, id: imageId) else {
                    throw AppDatabaseError.missingImage(imageId)
                }
                try requirePost(postId: saveImage.postId, in: db)
                try promotePostGraphToUserContent(postId: storedImage.postId, in: db)
                try promotePostGraphToUserContent(postId: saveImage.postId, in: db)
                try saveImage.updateWithTimestamp(db)
                try enqueueCloudKitSaveIfNeeded(recordType: .image, syncId: saveImage.syncId, modificationTime: saveImage.modificationTime, in: db)
                try touchPostForCloudKit(postId: storedImage.postId, modificationTime: saveImage.modificationTime, in: db)
                if storedImage.postId != saveImage.postId {
                    try touchPostForCloudKit(postId: saveImage.postId, modificationTime: saveImage.modificationTime, in: db)
                }
            }
        }
        catch {
            print(error)
            return false
        }
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
        return true
    }
    
    func delete(image: PostImage) -> Bool {
        guard let imageId = image.id else {
            return false
        }
        do {
            _ = try dbWriter?.write{ db in
                if let storedImage = try PostImage.fetchOne(db, id: imageId) {
                    let modificationTime = try db.transactionDate.nanoSecondSince1970
                    try enqueueCloudKitDeleteIfNeeded(recordType: .image, syncId: storedImage.syncId, in: db)
                    try touchPostForCloudKit(postId: storedImage.postId, modificationTime: modificationTime, in: db)
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
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
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
                let modificationTime = try db.transactionDate.nanoSecondSince1970
                for image in storedImages {
                    try enqueueCloudKitDeleteIfNeeded(recordType: .image, syncId: image.syncId, in: db)
                }
                for postId in Set(storedImages.map(\.postId)) {
                    try touchPostForCloudKit(postId: postId, modificationTime: modificationTime, in: db)
                }
                try PostImage.deleteAll(db, ids: imageIds)
                try OnboardingLocalRecord.unmark(recordType: .image, syncIds: storedImages.map(\.syncId), in: db)
            }
        }
        catch {
            print(error)
            return false
        }
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
        return true
    }
}

extension AppDatabase {
    func add(text: PostText) -> Bool {
        guard text.id == nil else {
            return false
        }
        do {
            try dbWriter?.write{ db in
                var saveText = text
                try requirePost(postId: saveText.postId, in: db)
                try promotePostGraphToUserContent(postId: saveText.postId, in: db)
                try saveText.save(db)
                try enqueueCloudKitSaveIfNeeded(recordType: .text, syncId: saveText.syncId, modificationTime: saveText.modificationTime, in: db)
                try touchPostForCloudKit(postId: saveText.postId, modificationTime: saveText.modificationTime, in: db)
            }
        }
        catch {
            print(error)
            return false
        }
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
        return true
    }
    
    func update(text: PostText) -> Bool {
        guard let textId = text.id else {
            return false
        }
        do {
            _ = try dbWriter?.write{ db in
                var saveText = text
                guard let storedText = try PostText.fetchOne(db, id: textId) else {
                    throw AppDatabaseError.missingText(textId)
                }
                try requirePost(postId: saveText.postId, in: db)
                try promotePostGraphToUserContent(postId: storedText.postId, in: db)
                try promotePostGraphToUserContent(postId: saveText.postId, in: db)
                try saveText.updateWithTimestamp(db)
                try enqueueCloudKitSaveIfNeeded(recordType: .text, syncId: saveText.syncId, modificationTime: saveText.modificationTime, in: db)
                try touchPostForCloudKit(postId: storedText.postId, modificationTime: saveText.modificationTime, in: db)
                if storedText.postId != saveText.postId {
                    try touchPostForCloudKit(postId: saveText.postId, modificationTime: saveText.modificationTime, in: db)
                }
            }
        }
        catch {
            print(error)
            return false
        }
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
        return true
    }
    
    func delete(text: PostText) -> Bool {
        guard let textId = text.id else {
            return false
        }
        do {
            _ = try dbWriter?.write{ db in
                if let storedText = try PostText.fetchOne(db, id: textId) {
                    let modificationTime = try db.transactionDate.nanoSecondSince1970
                    try enqueueCloudKitDeleteIfNeeded(recordType: .text, syncId: storedText.syncId, in: db)
                    try touchPostForCloudKit(postId: storedText.postId, modificationTime: modificationTime, in: db)
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
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
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
                let modificationTime = try db.transactionDate.nanoSecondSince1970
                for text in storedTexts {
                    try enqueueCloudKitDeleteIfNeeded(recordType: .text, syncId: text.syncId, in: db)
                }
                for postId in Set(storedTexts.map(\.postId)) {
                    try touchPostForCloudKit(postId: postId, modificationTime: modificationTime, in: db)
                }
                try PostText.deleteAll(db, ids: textIds)
                try OnboardingLocalRecord.unmark(recordType: .text, syncIds: storedTexts.map(\.syncId), in: db)
            }
        }
        catch {
            print(error)
            return false
        }
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
        return true
    }
}

extension AppDatabase {
    public func update(postIds: [Int64], isPinned: Bool, newOrder: Int64, promotesLocalOnboarding: Bool = true) -> Bool {
        do {
            _ = try dbWriter?.write{ db in
                try postIds.enumerated().forEach { (index, id) in
                    guard var post = try Post.fetchOne(db, id: id) else {
                        return
                    }
                    post.isPinned = isPinned
                    post.order = newOrder + Int64(index)
                    if promotesLocalOnboarding, let id = post.id {
                        try promotePostGraphToUserContent(postId: id, in: db)
                    }
                    try post.updateWithTimestamp(db)
                    try enqueueCloudKitSaveIfNeeded(recordType: .post, syncId: post.syncId, modificationTime: post.modificationTime, in: db)
                }
            }
        }
        catch {
            print(error)
            return false
        }
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
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
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
        return true
    }
    
    public func update(posts: [Post]) -> Bool {
        do {
            _ = try dbWriter?.write{ db in
                for var post in posts {
                    if let postId = post.id {
                        try promotePostGraphToUserContent(postId: postId, in: db)
                    }
                    try post.updateWithTimestamp(db)
                    try enqueueCloudKitSaveIfNeeded(recordType: .post, syncId: post.syncId, modificationTime: post.modificationTime, in: db)
                }
            }
        }
        catch {
            print(error)
            return false
        }
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
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
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
        NotificationCenter.default.post(name: Notification.Name.DatabaseStyleUpdated, object: nil)
        return saveStyle
    }
    
    func update(style: PostStyle) -> Bool {
        guard style.id != nil else {
            return false
        }
        do {
            _ = try dbWriter?.write{ db in
                var saveStyle = style
                if let styleId = saveStyle.id {
                    try promoteStyleToUserContent(styleId: styleId, in: db)
                }
                try saveStyle.updateWithTimestamp(db)
                try enqueueCloudKitSaveIfNeeded(recordType: .style, syncId: saveStyle.syncId, modificationTime: saveStyle.modificationTime, in: db)
            }
        }
        catch {
            print(error)
            return false
        }
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
        NotificationCenter.default.post(name: Notification.Name.DatabaseStyleUpdated, object: nil)
        return true
    }
    
    func delete(style: PostStyle) -> Bool {
        guard let styleId = style.id else {
            return false
        }
        do {
            _ = try dbWriter?.write{ db in
                let storedStyle = try PostStyle.fetchOne(db, id: styleId)
                let fallbackStyle = try PostStyle
                    .filter(PostStyle.Columns.id != styleId)
                    .order(PostStyle.Columns.id.asc)
                    .fetchOne(db)
                if let storedStyle {
                    try enqueueCloudKitDeleteIfNeeded(recordType: .style, syncId: storedStyle.syncId, in: db)
                }
                let decorations = try PostDecoration
                    .filter(Column(PostDecoration.CodingKeys.styleId) == styleId)
                    .fetchAll(db)
                for decoration in decorations {
                    try enqueueCloudKitDeleteIfNeeded(recordType: .decoration, syncId: decoration.syncId, in: db)
                }
                try PostDecoration.deleteAll(db, ids: decorations.compactMap(\.id))
                try PostStyle.deleteAll(db, ids: [styleId])
                if let storedStyle {
                    let deletionTime = try db.transactionDate.nanoSecondSince1970
                    let tracksCloudKit = tracksLocalCloudKitChanges()
                    if try DefaultStyle.replaceDeletedStyleIfNeeded(
                        deletedStyle: storedStyle,
                        fallbackStyle: fallbackStyle,
                        modificationTime: deletionTime,
                        updatesCloudKitSetting: tracksCloudKit,
                        in: db
                    ), tracksCloudKit {
                        try CloudKitOutboxEntry.enqueueSetting(
                            modificationTime: deletionTime,
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
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
        NotificationCenter.default.post(name: Notification.Name.DatabaseStyleUpdated, object: nil)
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
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
        NotificationCenter.default.post(name: Notification.Name.DatabaseStyleUpdated, object: nil)
        return true
    }
    
    func update(decoration: PostDecoration) -> Bool {
        guard let decorationId = decoration.id else {
            return false
        }
        do {
            _ = try dbWriter?.write{ db in
                var saveDecoration = decoration
                guard let storedDecoration = try PostDecoration.fetchOne(db, id: decorationId) else {
                    throw AppDatabaseError.missingDecoration(decorationId)
                }
                try requirePost(postId: saveDecoration.postId, in: db)
                try requireStyle(styleId: saveDecoration.styleId, in: db)
                try promotePostGraphToUserContent(postId: storedDecoration.postId, in: db)
                try promotePostGraphToUserContent(postId: saveDecoration.postId, in: db)
                try promoteStyleToUserContent(styleId: storedDecoration.styleId, in: db)
                try promoteStyleToUserContent(styleId: saveDecoration.styleId, in: db)
                try deleteConflictingDecorations(postId: saveDecoration.postId, excludingId: decorationId, in: db)
                try saveDecoration.updateWithTimestamp(db)
                try enqueueCloudKitSaveIfNeeded(recordType: .decoration, syncId: saveDecoration.syncId, modificationTime: saveDecoration.modificationTime, in: db)
                try touchPostForCloudKit(postId: storedDecoration.postId, modificationTime: saveDecoration.modificationTime, in: db)
                try touchStyleForCloudKit(styleId: storedDecoration.styleId, modificationTime: saveDecoration.modificationTime, in: db)
                if storedDecoration.postId != saveDecoration.postId {
                    try touchPostForCloudKit(postId: saveDecoration.postId, modificationTime: saveDecoration.modificationTime, in: db)
                }
                if storedDecoration.styleId != saveDecoration.styleId {
                    try touchStyleForCloudKit(styleId: saveDecoration.styleId, modificationTime: saveDecoration.modificationTime, in: db)
                }
            }
        }
        catch {
            print(error)
            return false
        }
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
        NotificationCenter.default.post(name: Notification.Name.DatabaseStyleUpdated, object: nil)
        return true
    }
    
    func delete(decoration: PostDecoration) -> Bool {
        guard let decorationId = decoration.id else {
            return false
        }
        do {
            _ = try dbWriter?.write{ db in
                if let storedDecoration = try PostDecoration.fetchOne(db, id: decorationId) {
                    let modificationTime = try db.transactionDate.nanoSecondSince1970
                    try enqueueCloudKitDeleteIfNeeded(recordType: .decoration, syncId: storedDecoration.syncId, in: db)
                    try touchPostForCloudKit(postId: storedDecoration.postId, modificationTime: modificationTime, in: db)
                    try touchStyleForCloudKit(styleId: storedDecoration.styleId, modificationTime: modificationTime, in: db)
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
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
        NotificationCenter.default.post(name: Notification.Name.DatabaseStyleUpdated, object: nil)
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

    func enqueueCloudKitDeleteIfNeeded(recordType: CloudKitRecordType, syncId: String, in db: Database) throws {
        guard try !OnboardingLocalRecord.isMarked(recordType: recordType, syncId: syncId, in: db) else { return }
        if tracksLocalCloudKitChanges() {
            try CloudKitOutboxEntry.enqueueDelete(recordType: recordType, syncId: syncId, in: db)
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
                deletionTime: try db.transactionDate.nanoSecondSince1970,
                in: db
            )
        }
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
            try enqueueCloudKitDeleteIfNeeded(recordType: .decoration, syncId: decoration.syncId, in: db)
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
        do {
            guard let dbWriter else { return false }
            if shouldRebuildCloudKit {
                CloudKitRecordSyncManager.shared.cancelSyncForLocalReset()
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
            if shouldRebuildCloudKit {
                CloudKitSync.setPendingRemoteReset(true)
            }
        } catch {
            print(error)
            return false
        }
        
        OnboardingManager.shared.requestOnboardingSeed()
        NotificationCenter.default.post(name: Notification.Name.DatabaseUpdated, object: nil)
        return true
    }
}

extension AppDatabase {
    /// Provides a read-only access to the database
    var reader: DatabaseReader? {
        dbWriter
    }
}
