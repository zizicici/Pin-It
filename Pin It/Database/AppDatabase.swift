//
//  AppDatabase.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/17.
//

import Foundation
import GRDB

extension Notification.Name {
    static let DatabaseUpdated = Notification.Name(rawValue: "com.zizicici.common.database.updated")
    static let DatabaseStyleUpdated = Notification.Name(rawValue: "com.zizicici.common.database.updated.style")
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
    
    func update(post: Post) -> Bool {
        guard post.id != nil else {
            return false
        }
        do {
            _ = try dbWriter?.write{ db in
                var savePost = post
                try savePost.updateWithTimestamp(db)
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
                try Post.deleteAll(db, ids: [postId])
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
                try Post.deleteAll(db, ids: ids)
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
                try saveImage.save(db)
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
        guard image.id != nil else {
            return false
        }
        do {
            _ = try dbWriter?.write{ db in
                try image.update(db)
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
                try PostImage.deleteAll(db, ids: [imageId])
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
                try PostImage.deleteAll(db, ids: imageIds)
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
                try saveText.save(db)
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
        guard text.id != nil else {
            return false
        }
        do {
            _ = try dbWriter?.write{ db in
                try text.update(db)
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
                try PostText.deleteAll(db, ids: [textId])
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
                try PostText.deleteAll(db, ids: textIds)
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
    public func update(postIds: [Int64], isPinned: Bool, newOrder: Int64) -> Bool {
        do {
            _ = try dbWriter?.write{ db in
                try postIds.enumerated().forEach { (index, id) in
                    var post = try Post.fetchOne(db, id: id)
                    post?.isPinned = isPinned
                    post?.order = newOrder + Int64(index)
                    try post?.updateWithTimestamp(db)
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
    
    public func update(posts: [Post]) -> Bool {
        do {
            _ = try dbWriter?.write{ db in
                for var post in posts {
                    try? post.updateWithTimestamp(db)
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
                try style.update(db)
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
        guard let textId = style.id else {
            return false
        }
        do {
            _ = try dbWriter?.write{ db in
                try PostStyle.deleteAll(db, ids: [textId])
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
                var saveStyle = decoration
                try saveStyle.save(db)
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
        guard decoration.id != nil else {
            return false
        }
        do {
            _ = try dbWriter?.write{ db in
                try decoration.update(db)
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
        guard let textId = decoration.id else {
            return false
        }
        do {
            _ = try dbWriter?.write{ db in
                try PostDecoration.deleteAll(db, ids: [textId])
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
    public func reset() -> Bool {
        disconnect()
        
        do {
            let databasePool = try AppDatabase.generateDatabasePool()
            try databasePool.erase()
        }
        catch {
            reconnect()
            print(error)
            return false
        }
        reconnect()
        
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
