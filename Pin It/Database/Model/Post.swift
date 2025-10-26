//
//  Post.swift
//  Pin It
//
//  Created by Salley Garden on 2025/10/17.
//

import Foundation
import GRDB

struct Post: Identifiable, Hashable, Codable {
    struct Detail: Codable, FetchableRecord, Hashable {
        var post: Post
        var images: [PostImage]
        var texts: [PostText]
        
        var title: String {
            return texts.first?.content ?? ""
        }
    }
    
    var id: Int64?
    
    var creationTime: Int64?
    var modificationTime: Int64?
    
    var isPinned: Bool
    var order: Int64
    
    enum Columns: String, ColumnExpression {
        case id
        case order
        
        static let isPinned = Column(CodingKeys.isPinned)
        static let modificationTime = Column(CodingKeys.modificationTime)
    }
    
    enum CodingKeys: String, CodingKey {
        case id, creationTime = "creation_time", modificationTime = "modification_time", isPinned = "is_pinned", order
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
    
    var images: QueryInterfaceRequest<PostImage> {
        request(for: Post.images)
    }
    
    static let texts = hasMany(PostText.self).forKey("texts").order(PostText.Columns.order.asc)
    
    var texts: QueryInterfaceRequest<PostText> {
        request(for: Post.texts)
    }
}
