//
//  Post.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/17.
//

import Foundation
import GRDB
import MoreKit

struct Post: Identifiable, Hashable, Codable {
    struct Detail: Codable, FetchableRecord, Hashable {
        var post: Post
        var images: [PostImage]
        var texts: [PostText]
        var style: PostStyle?
        
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
    var syncId: String = UUID().uuidString
    
    var creationTime: Int64?
    var modificationTime: Int64?
    
    var expirationTime: Int64?
    var actionLink: String
    
    var isPinned: Bool
    var order: Int64
    
    enum Columns: String, ColumnExpression {
        case id
        case order
        
        static let isPinned = Column(CodingKeys.isPinned)
        static let modificationTime = Column(CodingKeys.modificationTime)
        static let syncId = Column(CodingKeys.syncId)
    }
    
    enum CodingKeys: String, CodingKey {
        case id, syncId = "sync_id", creationTime = "creation_time", modificationTime = "modification_time", expirationTime = "expiration_time", actionLink = "action_link", isPinned = "is_pinned", order
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
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int64.self, forKey: .id)
        syncId = try container.decodeIfPresent(String.self, forKey: .syncId) ?? UUID().uuidString
        creationTime = try container.decodeIfPresent(Int64.self, forKey: .creationTime)
        modificationTime = try container.decodeIfPresent(Int64.self, forKey: .modificationTime)
        expirationTime = try container.decodeIfPresent(Int64.self, forKey: .expirationTime)
        actionLink = try container.decodeIfPresent(String.self, forKey: .actionLink) ?? ""
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        order = try container.decodeIfPresent(Int64.self, forKey: .order) ?? 0
    }
}

extension Post {
    static let images = hasMany(PostImage.self, using: PostImage.postForeignKey).forKey("images").order(PostImage.Columns.order.asc)
    
    var images: QueryInterfaceRequest<PostImage> {
        request(for: Post.images)
    }
    
    static let texts = hasMany(PostText.self, using: PostText.postForeignKey).forKey("texts").order(PostText.Columns.order.asc)
    
    var texts: QueryInterfaceRequest<PostText> {
        request(for: Post.texts)
    }
}

extension Post {
    static let decoration = hasOne(PostDecoration.self, using: PostDecoration.postForeignKey)
}

let formatter = DateFormatter()

extension Post {
    var updateText: String {
        guard let modificationTime = modificationTime else { return "" }
        let date = Date(timeIntervalSince1970: Double(modificationTime) / 1000.0)
        
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        
        return formatter.string(from: date)
    }
    
    var createText: String {
        guard let creationTime = creationTime else { return "" }
        let date = Date(timeIntervalSince1970: Double(creationTime) / 1000.0)
        
        formatter.dateStyle = .medium
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
    
    var activedStyle: PostStyle? {
        var result: PostStyle?
        if style == nil {
            let id = Int64(DefaultStyle.getValue().rawValue)
            result = DataManager.shared.fetchStyle(by: id)
        } else {
            result = style
        }
        if result == nil {
            result = DataManager.shared.fetchAllStyles().first
        }
        return result
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
    
    static func placeholder() -> Post {
        return .init(expirationTime: getDefaultExpirationTime(), actionLink: "", isPinned: false, order: 0)
    }
    
    static func getDefaultExpirationTime() -> Int64? {
        guard DefaultExpirationTime.current.duration != nil else {
            return nil
        }
        let seconds = DefaultExpirationTime.current.rawValue
        return Date(timeIntervalSinceNow: TimeInterval(seconds)).nanoSecondSince1970
    }
}
