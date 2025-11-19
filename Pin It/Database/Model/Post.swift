//
//  Post.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/17.
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
        
        var maxOrder: Int64 {
            let imagesMax = images.max(by: { $0.order < $1.order })?.order ?? 0
            let textsMax = texts.max(by: { $0.order < $1.order })?.order ?? 0
            return max(imagesMax, textsMax)
        }
    }
    
    var id: Int64?
    
    var creationTime: Int64?
    var modificationTime: Int64?
    
    var expirationTime: Int64?
    
    var isPinned: Bool
    var order: Int64
    
    enum Columns: String, ColumnExpression {
        case id
        case order
        
        static let isPinned = Column(CodingKeys.isPinned)
        static let modificationTime = Column(CodingKeys.modificationTime)
    }
    
    enum CodingKeys: String, CodingKey {
        case id, creationTime = "creation_time", modificationTime = "modification_time", expirationTime = "expiration_time", isPinned = "is_pinned", order
    }
    
    static let placeholder: Self = .init(isPinned: false, order: 0)
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

let formatter = DateFormatter()

extension Post {
    var updateText: String {
        guard let modificationTime = modificationTime else { return "" }
        let date = Date(timeIntervalSince1970: Double(modificationTime) / 1000.0)
        
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        
        return formatter.string(from: date)
    }
    
    var createText: String {
        guard let creationTime = creationTime else { return "" }
        let date = Date(timeIntervalSince1970: Double(creationTime) / 1000.0)
        
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        
        return formatter.string(from: date)
    }
}

extension Post.Detail {
    enum DetailType {
        case text
        case image
    }
    
    var detailType: DetailType {
        if images.count > 0 {
            return .image
        } else {
            return .text
        }
    }
}

extension Post {
    func isExpired() -> Bool {
        if let expirationTime = expirationTime {
            return Int(Date().timeIntervalSince1970 * 1000) > expirationTime
        } else {
            return false
        }
    }
}
