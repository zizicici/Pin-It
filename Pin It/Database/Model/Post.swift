//
//  Post.swift
//  Pin It
//
//  Created by Salley Garden on 2025/10/17.
//

import Foundation
import GRDB

struct Post: Identifiable, Hashable, Codable {
    struct Detail: Decodable, FetchableRecord, Hashable {
        var post: Post
        var images: [PostImage]
        var texts: [PostText]
        
        var title: String {
            return post.title
        }
    }
    
    var id: Int64?
    
    var creationTime: Int64?
    var modificationTime: Int64?
    
    var title: String
    var order: Int64
    
    enum Columns: String, ColumnExpression {
        case order
    }
    
    enum CodingKeys: String, CodingKey {
        case id, creationTime = "creation_time", modificationTime = "modification_time", title, order
    }
}

extension Post: TableRecord {
    static var databaseTableName: String = "post"
}

extension Post: FetchableRecord {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Post: TimestampedRecord {
    
}

extension Post {
    static let images = hasMany(PostImage.self).forKey("images").order(PostImage.Columns.order.asc)
    
    static let texts = hasMany(PostText.self).forKey("texts").order(PostText.Columns.order.asc)
}
