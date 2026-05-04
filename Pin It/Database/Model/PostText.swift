//
//  PostText.swift
//  Pin It
//
//  Created by Ci Zi on 2025/10/17.
//

import Foundation
import GRDB

struct PostText: Identifiable, Hashable, Codable {
    var id: Int64?
    var syncId: String = UUID().uuidString

    var creationTime: Int64?
    var modificationTime: Int64?
    
    var postId: Int64
    var content: String
    
    var order: Int64
    
    enum Columns: String, ColumnExpression {
        case order

        static let postId = Column(CodingKeys.postId)
        static let syncId = Column(CodingKeys.syncId)
    }
    
    enum CodingKeys: String, CodingKey {
        case id, syncId = "sync_id", creationTime = "creation_time", modificationTime = "modification_time", postId = "post_id", content, order
    }
}

extension PostText: TableRecord {
    static var databaseTableName: String = "text"
}

extension PostText: FetchableRecord {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension PostText: TimestampedRecord {
    
}

extension PostText {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int64.self, forKey: .id)
        syncId = try container.decodeIfPresent(String.self, forKey: .syncId) ?? UUID().uuidString
        creationTime = try container.decodeIfPresent(Int64.self, forKey: .creationTime)
        modificationTime = try container.decodeIfPresent(Int64.self, forKey: .modificationTime)
        postId = try container.decode(Int64.self, forKey: .postId)
        content = try container.decode(String.self, forKey: .content)
        order = try container.decodeIfPresent(Int64.self, forKey: .order) ?? 0
    }
}

extension PostText {
    static let postForeignKey = ForeignKey([Columns.postId])
}
