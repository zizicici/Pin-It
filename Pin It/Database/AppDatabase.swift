//
//  AppDatabase.swift
//  Pin It
//
//  Created by Salley Garden on 2025/10/17.
//

import Foundation
import GRDB

extension Notification.Name {
    static let DatabaseUpdated = Notification.Name(rawValue: "com.zizicici.common.database.updated")
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
                
                table.column("title", .text).notNull()
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
                table.column("cropped", .text).notNull()
                table.column("orientation", .integer).notNull()
                table.column("min_x", .integer).notNull()
                table.column("min_y", .integer).notNull()
                table.column("max_x", .integer).notNull()
                table.column("max_y", .integer).notNull()
                
                table.column("order", .integer).notNull()
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
}

extension AppDatabase {
    /// Provides a read-only access to the database
    var reader: DatabaseReader? {
        dbWriter
    }
}
